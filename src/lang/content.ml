(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2022 Savonet team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details, fully stated in the COPYING
  file at the root of the liquidsoap distribution.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA

 *****************************************************************************)

module Contents = struct
  type format = ..
  type kind = ..
  type _type = int
  type content = ..
  type data = _type * content

  let _type = ref 0

  let register_type () =
    incr _type;
    !_type
end

let merge_param ~name = function
  | None, None -> None
  | None, Some p | Some p, None -> Some p
  | Some p, Some p' when p = p' -> Some p
  | _ -> failwith ("Incompatible " ^ name)

let print_optional l =
  String.concat ","
    (List.fold_left
       (fun cur (lbl, v) ->
         match v with None -> cur | Some v -> (lbl ^ "=" ^ v) :: cur)
       [] l)

exception Invalid
exception Incompatible_format of Contents.format * Contents.format

type internal_content_type = [ `None | `Audio | `Video | `Midi ]

module type ContentSpecs = sig
  type kind
  type params
  type data

  val internal_content_type : internal_content_type option
  val make : size:int -> params -> data
  val blit : data -> int -> data -> int -> int -> unit
  val fill : data -> int -> data -> int -> int -> unit
  val sub : data -> int -> int -> data
  val copy : data -> data
  val clear : data -> unit
  val is_empty : data -> bool
  val params : data -> params
  val merge : params -> params -> params
  val compatible : params -> params -> bool
  val string_of_params : params -> string
  val parse_param : string -> string -> params option
  val kind : kind
  val default_params : kind -> params
  val string_of_kind : kind -> string
  val kind_of_string : string -> kind option
end

module type Content = sig
  include ContentSpecs

  val is_data : Contents.data -> bool
  val lift_data : data -> Contents.data
  val get_data : Contents.data -> data
  val is_format : Contents.format -> bool
  val lift_params : params -> Contents.format
  val get_params : Contents.format -> params
  val is_kind : Contents.kind -> bool
  val lift_kind : kind -> Contents.kind
  val get_kind : Contents.kind -> kind
end

type data = Contents.data
type kind = Contents.kind

type kind_handler = {
  default_format : unit -> Contents.format;
  string_of_kind : unit -> string;
}

let kind_handlers = Queue.create ()
let register_kind_handler fn = Queue.add fn kind_handlers

exception Found_kind of kind_handler

let get_kind_handler f =
  try
    Queue.iter
      (fun fn -> match fn f with Some h -> raise (Found_kind h) | None -> ())
      kind_handlers;
    raise Invalid
  with Found_kind h -> h

let kind_parsers = Queue.create ()

exception Parsed_kind of kind

let kind_of_string s =
  try
    Queue.iter
      (fun fn -> match fn s with Some f -> raise (Parsed_kind f) | None -> ())
      kind_parsers;
    raise Invalid
  with Parsed_kind f -> f

type format = Contents.format

type format_handler = {
  kind : unit -> kind;
  make : int -> data;
  string_of_format : unit -> string;
  merge : format -> unit;
  compatible : format -> bool;
  duplicate : unit -> format;
}

let format_handlers = Queue.create ()
let register_format_handler fn = Queue.add fn format_handlers

exception Found_format of format_handler

let get_params_handler p =
  try
    Queue.iter
      (fun fn ->
        match fn p with Some h -> raise (Found_format h) | None -> ())
      format_handlers;
    raise Invalid
  with Found_format h -> h

let format_parsers = Queue.create ()

exception Parsed_format of format

let parse_param kind label value =
  try
    Queue.iter
      (fun fn ->
        match fn kind label value with
          | Some p -> raise (Parsed_format p)
          | None -> ())
      format_parsers;
    raise Invalid
  with Parsed_format p -> p

type data_handler = {
  blit : data -> int -> data -> int -> int -> unit;
  fill : data -> int -> data -> int -> int -> unit;
  sub : data -> int -> int -> data;
  is_empty : data -> bool;
  copy : data -> data;
  format : data -> format;
  clear : data -> unit;
}

let dummy_handler =
  {
    blit = (fun _ _ _ _ _ -> assert false);
    fill = (fun _ _ _ _ _ -> assert false);
    sub = (fun _ _ _ -> assert false);
    is_empty = (fun _ -> assert false);
    copy = (fun _ -> assert false);
    format = (fun _ -> assert false);
    clear = (fun _ -> assert false);
  }

let data_handlers = Array.make 12 dummy_handler

let register_data_handler t h =
  if Array.length data_handlers - 1 < t then
    failwith "Please increase media content array size!";
  Array.unsafe_set data_handlers t h

let get_data_handler (t, _) = Array.unsafe_get data_handlers t
let make ~size k = (get_params_handler k).make size
let blit src = (get_data_handler src).blit src
let fill src = (get_data_handler src).fill src
let sub d = (get_data_handler d).sub d
let is_empty c = (get_data_handler c).is_empty c
let copy c = (get_data_handler c).copy c
let format c = (get_data_handler c).format c
let clear c = (get_data_handler c).clear c
let kind p = (get_params_handler p).kind ()
let default_format f = (get_kind_handler f).default_format ()
let string_of_format k = (get_params_handler k).string_of_format ()

let () =
  Printexc.register_printer (function
    | Incompatible_format (f, f') ->
        Some
          (Printf.sprintf
             "Content.Incompatible_format: formats %s and %s are incompatible!"
             (string_of_format f) (string_of_format f'))
    | _ -> None)

let merge p p' =
  let { merge } = get_params_handler p in
  try merge p' with _ -> raise (Incompatible_format (p, p'))

let duplicate p = (get_params_handler p).duplicate ()
let compatible p p' = (get_params_handler p).compatible p'
let string_of_kind f = (get_kind_handler f).string_of_kind ()

type internal_entry = { is_kind : kind -> bool; is_format : format -> bool }

type internal_entries = {
  mutable none : internal_entry option;
  mutable audio : internal_entry option;
  mutable video : internal_entry option;
  mutable midi : internal_entry option;
}

let internal_entries = { none = None; audio = None; video = None; midi = None }

module MkContent (C : ContentSpecs) :
  Content
    with type kind = C.kind
     and type params = C.params
     and type data = C.data = struct
  type Contents.kind += Kind of C.kind
  type Contents.format += Format of C.params Unifier.t
  type Contents.content += Content of C.data

  let _type = Contents.register_type ()
  let data = function _, Content d -> d | _ -> assert false

  let blit src src_ofs dst dst_ofs len =
    let src = data src in
    let dst = data dst in
    C.blit src src_ofs dst dst_ofs len

  let fill src src_ofs dst dst_ofs len =
    let src = data src in
    let dst = data dst in
    C.fill src src_ofs dst dst_ofs len

  let merge p p' =
    let p' = match p' with Format p' -> p' | _ -> raise Invalid in
    let m = C.merge (Unifier.deref p) (Unifier.deref p') in
    Unifier.set p' m;
    Unifier.(p <-- p')

  let compatible p p' =
    match p' with
      | Format p' -> C.compatible (Unifier.deref p) (Unifier.deref p')
      | _ -> false

  let kind_of_string s = Option.map (fun p -> Kind p) (C.kind_of_string s)

  let format_of_string kind label value =
    match kind with
      | Kind _ ->
          Option.map
            (fun p -> Format (Unifier.make p))
            (C.parse_param label value)
      | _ -> None

  let () =
    register_kind_handler (function
      | Kind f ->
          Some
            {
              default_format =
                (fun () -> Format (Unifier.make (C.default_params f)));
              string_of_kind = (fun () -> C.string_of_kind f);
            }
      | _ -> None);
    register_format_handler (function
      | Format p ->
          Some
            {
              kind = (fun () -> Kind C.kind);
              make =
                (fun size -> (_type, Content (C.make ~size (Unifier.deref p))));
              merge = (fun p' -> merge p p');
              duplicate = (fun () -> Format Unifier.(make (deref p)));
              compatible = (fun p' -> compatible p p');
              string_of_format =
                (fun () ->
                  let kind = C.string_of_kind C.kind in
                  let params = C.string_of_params (Unifier.deref p) in
                  match params with
                    | "" -> C.string_of_kind C.kind
                    | _ -> Printf.sprintf "%s(%s)" kind params);
            }
      | _ -> None);
    Queue.push kind_of_string kind_parsers;
    Queue.push format_of_string format_parsers;
    let data_handler =
      {
        blit;
        fill;
        sub = (fun d ofs len -> (_type, Content (C.sub (data d) ofs len)));
        is_empty = (fun d -> C.is_empty (data d));
        copy = (fun d -> (_type, Content (C.copy (data d))));
        format = (fun d -> Format (Unifier.make (C.params (data d))));
        clear = (fun d -> C.clear (data d));
      }
    in
    register_data_handler _type data_handler

  let is_kind = function Kind _ -> true | _ -> false
  let lift_kind f = Kind f
  let get_kind = function Kind f -> f | _ -> raise Invalid
  let is_format = function Format _ -> true | _ -> false
  let lift_params p = Format (Unifier.make p)
  let get_params = function Format p -> Unifier.deref p | _ -> raise Invalid
  let is_data = function _, Content _ -> true | _ -> false
  let lift_data d = (_type, Content d)
  let get_data = function _type, Content d -> d | _ -> raise Invalid

  let () =
    let entry = { is_kind; is_format } in
    match C.internal_content_type with
      | None -> ()
      | Some `None -> internal_entries.none <- Some entry
      | Some `Audio -> internal_entries.audio <- Some entry
      | Some `Video -> internal_entries.video <- Some entry
      | Some `Midi -> internal_entries.midi <- Some entry

  include C
end

module NoneSpecs = struct
  type kind = unit
  type params = unit
  type data = unit

  let internal_content_type = Some `None
  let is_empty _ = true
  let make ~size:_ _ = ()
  let clear _ = ()
  let blit _ _ _ _ _ = ()
  let fill _ _ _ _ _ = ()
  let sub _ _ _ = ()
  let copy _ = ()
  let params _ = ()
  let merge _ _ = ()
  let compatible _ _ = true
  let string_of_params _ = ""
  let parse_param _ _ = None
  let kind = ()
  let default_params () = ()
  let string_of_kind () = "none"
  let kind_of_string = function "none" -> Some () | _ -> None
end

module None = struct
  include MkContent (NoneSpecs)

  let data = lift_data ()
  let format = lift_params ()
end

let is_internal_entry_kind f = function
  | Some { is_kind } -> is_kind f
  | None -> false

let is_internal_kind f =
  is_internal_entry_kind f internal_entries.none
  || is_internal_entry_kind f internal_entries.audio
  || is_internal_entry_kind f internal_entries.video
  || is_internal_entry_kind f internal_entries.midi

let is_internal_entry_format f = function
  | Some { is_format } -> is_format f
  | None -> false

let is_internal_format f =
  is_internal_entry_format f internal_entries.none
  || is_internal_entry_format f internal_entries.audio
  || is_internal_entry_format f internal_entries.video
  || is_internal_entry_format f internal_entries.midi
