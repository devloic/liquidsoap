(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2021 Savonet team

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

(** User-friendly representation of types. *)

(** Show generalized variables in records. *)
let show_record_schemes = ref true

open Type

let string_of_single_pos = Runtime_error.print_single_pos
let string_of_pos = Runtime_error.print_pos
let string_of_pos_opt = Runtime_error.print_pos_opt
let string_of_pos_list = Runtime_error.print_pos_list

type t =
  [ `Constr of string * (variance * t) list
  | `Ground of ground
  | `List of t * [ `Object | `Tuple ]
  | `Tuple of t list
  | `Nullable of t
  | `Meth of
    string * (var list * t) * string option * t
    (* label, type scheme, JSON name, base type *)
  | `Arrow of (bool * string * t) list * t
  | `Getter of t
  | `EVar of t option * var * t option (* existential variable *)
  | `UVar of t option * var * t option (* universal variable *)
  | `Ellipsis (* omitted sub-term *)
  | `Range_Ellipsis (* omitted sub-terms (in a list, e.g. list of args) *)
  | `Debug of
    string * t * string
    (* add annotations before / after, mostly used for debugging *) ]

and var = string * constraints

(** Given a strictly positive integer, generate a name in [a-z]+:
    a, b, ... z, aa, ab, ... az, ba, ... *)
let name =
  let base = 26 in
  let c i = char_of_int (int_of_char 'a' + i - 1) in
  let add i suffix = Printf.sprintf "%c%s" (c i) suffix in
  let rec n suffix i =
    if i <= base then add i suffix
    else (
      let head = i mod base in
      let head = if head = 0 then base else head in
      n (add head suffix) ((i - head) / base))
  in
  n ""

(** Generate a globally unique name for evars (used for debugging only). *)
let evar_global_name =
  let evars = Hashtbl.create 10 in
  let n = ref (-1) in
  fun i ->
    try Hashtbl.find evars i
    with Not_found ->
      incr n;
      let name = String.uppercase_ascii (name !n) in
      Hashtbl.add evars i name;
      name

(** Compute the structure that a term represents, given the list of universally
    quantified variables. Also takes care of computing the printing name of
    variables, including constraint symbols, which are removed from constraint
    lists. It supports a mechanism for filtering out parts of the type, which are
    then translated as `Ellipsis. *)
let make ?(filter_out = fun _ -> false) ?(generalized = []) t : t =
  let split_constr c =
    List.fold_left (fun (s, constraints) c -> (s, c :: constraints)) ("", []) c
  in
  let uvar ~lower ~upper g var =
    let constr_symbols, c = split_constr var.constraints in
    let rec index n = function
      | v :: tl ->
          if v = var then Printf.sprintf "'%s%s" constr_symbols (name n)
          else index (n + 1) tl
      | [] -> assert false
    in
    let v = index 1 (List.rev g) in
    (* let v = Printf.sprintf "'%d" i in *)
    `UVar (lower, (v, c), upper)
  in
  let counter =
    let c = ref 0 in
    fun () ->
      incr c;
      !c
  in
  let evars = Hashtbl.create 10 in
  let evar ~lower ~upper var =
    let constr_symbols, c = split_constr var.constraints in
    if !debug then (
      let v =
        Printf.sprintf "'%s%s" constr_symbols (evar_global_name var.name)
      in
      let v =
        if !debug_levels then (
          let level = var.level in
          let level = if level = max_int then "∞" else string_of_int level in
          Printf.sprintf "%s[%s]" v level)
        else v
      in
      `EVar (lower, (v, c), upper))
    else (
      let s =
        try Hashtbl.find evars var.name
        with Not_found ->
          let name = String.uppercase_ascii (name (counter ())) in
          Hashtbl.add evars var.name name;
          name
      in
      `EVar (lower, (Printf.sprintf "'%s%s" constr_symbols s, c), upper))
  in
  (* p is the polarity and g are generalized variables *)
  let rec repr g t =
    if filter_out t then `Ellipsis
    else (
      match t.descr with
        | Ground g -> `Ground g
        | Getter t -> `Getter (repr g t)
        | List { t; json_repr } -> `List (repr g t, json_repr)
        | Tuple l -> `Tuple (List.map (repr g) l)
        | Nullable t -> `Nullable (repr g t)
        | Meth ({ meth = l; scheme = g', u; json_name }, v) ->
            let gen =
              List.map
                (fun v ->
                  match uvar ~lower:None ~upper:None (g' @ g) v with
                    | `UVar (_, v, _) -> v)
                (List.sort_uniq compare g')
            in
            `Meth (l, (gen, repr (g' @ g) u), json_name, repr g v)
        | Constr { constructor; params } ->
            `Constr (constructor, List.map (fun (l, t) -> (l, repr g t)) params)
        | Arrow (args, t) ->
            `Arrow
              ( List.map (fun (opt, lbl, t) -> (opt, lbl, repr g t)) args,
                repr g t )
        | Var var ->
            let lower =
              if var.lower.descr = Var var then None
              else Some (repr g var.lower)
            in
            let upper =
              if var.upper.descr = Var var then None
              else Some (repr g var.upper)
            in
            if List.mem var g then uvar ~lower ~upper g var
            else evar ~lower ~upper var)
  in
  repr generalized t

(** Sets of type descriptions. *)
module DS = Set.Make (struct
  type t = string * constraints

  let compare = compare
end)

(** Print a type representation. Unless in debug mode, variable identifiers are
    not shown, and variable names are generated. Names are only meaningful over
    one printing, as they are re-used. *)
let print f (t : t) =
  (* Display the type and return the list of variables that occur in it.
   * The [par] params tells whether (..)->.. should be surrounded by
   * parenthesis or not. *)
  let rec print ~par vars : t -> DS.t = function
    | `Constr ("stream_kind", params) -> (
        (* Let's assume that stream_kind occurs only inside a source
         * or format type -- this should be pretty much true with the
         * current API -- and simplify the printing by labeling its
         * parameters and omitting the stream_kind(...) to avoid
         * source(stream_kind(pcm(stereo),none,none)). *)
        match params with
          | [(_, a); (_, v); (_, m)] ->
              let first, has_ellipsis, vars =
                List.fold_left
                  (fun (first, has_ellipsis, vars) (lbl, t) ->
                    if t = `Ellipsis then (false, true, vars)
                    else (
                      if not first then Format.fprintf f ",@ ";
                      Format.fprintf f "%s=" lbl;
                      let vars = print ~par:false vars t in
                      (false, has_ellipsis, vars)))
                  (true, false, vars)
                  [("audio", a); ("video", v); ("midi", m)]
              in
              if not has_ellipsis then vars
              else (
                if not first then Format.fprintf f ",@,";
                print ~par:false vars `Range_Ellipsis)
          | _ -> assert false)
    | `Constr ("none", _) ->
        Format.fprintf f "none";
        vars
    | `Constr (_, [(_, `Ground (Format format))]) ->
        Format.fprintf f "%s" (Content.string_of_format format);
        vars
    | `Constr (name, params) ->
        Format.open_box (1 + String.length name);
        Format.fprintf f "%s(" name;
        let vars = print_list vars params in
        Format.fprintf f ")";
        Format.close_box ();
        vars
    | `Ground g ->
        Format.fprintf f "%s" (string_of_ground g);
        vars
    | `Tuple [] ->
        Format.fprintf f "unit";
        vars
    | `Tuple l ->
        if par then Format.fprintf f "@[<1>(" else Format.fprintf f "@[<0>";
        let rec aux vars = function
          | [a] -> print ~par:true vars a
          | a :: l ->
              let vars = print ~par:true vars a in
              Format.fprintf f " *@ ";
              aux vars l
          | [] -> assert false
        in
        let vars = aux vars l in
        if par then Format.fprintf f ")@]" else Format.fprintf f "@]";
        vars
    | `Nullable t ->
        let vars = print ~par:true vars t in
        Format.fprintf f "?";
        vars
    | `Meth (l, (_, a), _, b) as t ->
        if not !debug then (
          (* Find all methods. *)
          let rec aux = function
            | `Meth (l, t, json_name, u) ->
                let m, u = aux u in
                ((l, t, json_name) :: m, u)
            | u -> ([], u)
          in
          let m, t = aux t in
          (* Filter out duplicates. *)
          let rec aux = function
            | (l, t, json_name) :: m ->
                (l, t, json_name)
                :: aux (List.filter (fun (l', _, _) -> l <> l') m)
            | [] -> []
          in
          let m = aux m in
          (* Put latest addition last. *)
          let m = List.rev m in
          (* First print the main value. *)
          let vars =
            if t = `Tuple [] then (
              Format.fprintf f "@,@[<hv 2>{@,";
              vars)
            else (
              let vars = print ~par:true vars t in
              Format.fprintf f "@,@[<hv 2>.{@,";
              vars)
          in
          let vars =
            if m = [] then vars
            else (
              let rec gen = function
                | (x, _) :: g -> x ^ "." ^ gen g
                | [] -> ""
              in
              let gen g =
                if !show_record_schemes then gen (List.sort compare g) else ""
              in
              let rec aux vars = function
                | [(l, (g, t), Some json_name)] ->
                    Format.fprintf f "%s as %s : %s"
                      (Utils.quote_utf8_string json_name)
                      l (gen g);
                    print ~par:true vars t
                | [(l, (g, t), None)] ->
                    Format.fprintf f "%s : %s" l (gen g);
                    print ~par:true vars t
                | (l, (g, t), Some json_name) :: m ->
                    Format.fprintf f "%s as %s : %s"
                      (Utils.quote_utf8_string json_name)
                      l (gen g);
                    let vars = print ~par:false vars t in
                    Format.fprintf f ",@ ";
                    aux vars m
                | (l, (g, t), None) :: m ->
                    Format.fprintf f "%s : %s" l (gen g);
                    let vars = print ~par:false vars t in
                    Format.fprintf f ",@ ";
                    aux vars m
                | [] -> assert false
              in
              aux vars m)
          in
          Format.fprintf f "@]@,}";
          vars)
        else (
          let vars = print ~par:true vars b in
          Format.fprintf f ".{%s = " l;
          let vars = print ~par:false vars a in
          Format.fprintf f "}";
          vars)
    | `List (t, `Tuple) ->
        Format.fprintf f "@[<1>[";
        let vars = print ~par:false vars t in
        Format.fprintf f "]@]";
        vars
    | `List (t, `Object) ->
        Format.fprintf f "@[<1>[";
        let vars = print ~par:false vars t in
        Format.fprintf f "] as json.object@]";
        vars
    | `Getter t ->
        Format.fprintf f "{";
        let vars = print ~par:false vars t in
        Format.fprintf f "}";
        vars
    | `EVar (_, (a, [InternalMedia]), _) ->
        Format.fprintf f "?internal(%s)" a;
        vars
    | `UVar (_, (a, [InternalMedia]), _) ->
        Format.fprintf f "internal(%s)" a;
        vars
    | `EVar (lower, (name, c), upper) | `UVar (lower, (name, c), upper) ->
        let vars =
          if lower = None && upper = None then (
            Format.fprintf f "%s" name;
            vars)
          else (
            Format.fprintf f "[";
            let vars =
              match lower with
                | None -> vars
                | Some lower -> print ~par:false vars lower
            in
            Format.fprintf f "< %s <" name;
            let vars =
              match upper with
                | None -> vars
                | Some upper -> print ~par:false vars upper
            in
            vars)
        in
        if c <> [] then DS.add (name, c) vars else vars
    | `Arrow (p, t) ->
        if par then Format.fprintf f "@[<hov 1>("
        else Format.fprintf f "@[<hov 0>";
        Format.fprintf f "@[<1>(";
        let _, vars =
          List.fold_left
            (fun (first, vars) (opt, lbl, kind) ->
              if not first then Format.fprintf f ",@ ";
              if opt then Format.fprintf f "?";
              if lbl <> "" then Format.fprintf f "%s : " lbl;
              let vars = print ~par:true vars kind in
              (false, vars))
            (true, vars) p
        in
        Format.fprintf f ")@] ->@ ";
        let vars = print ~par:false vars t in
        if par then Format.fprintf f ")@]" else Format.fprintf f "@]";
        vars
    | `Ellipsis ->
        Format.fprintf f "_";
        vars
    | `Range_Ellipsis ->
        Format.fprintf f "...";
        vars
    | `Debug (a, b, c) ->
        Format.fprintf f "%s" a;
        let vars = print ~par:false vars b in
        Format.fprintf f "%s" c;
        vars
  and print_list ?(first = true) ?(acc = []) vars = function
    | [] -> vars
    | (_, x) :: l ->
        if not first then Format.fprintf f ",";
        let vars = print ~par:false vars x in
        print_list ~first:false ~acc:(x :: acc) vars l
  in
  Format.fprintf f "@[";
  begin
    match t with
    (* We're only printing a variable: ignore its [repr]esentation. *)
    | `EVar (_, (_, c), _) when c <> [] ->
        Format.fprintf f "something that is %s"
          (String.concat " and " (List.map string_of_constr c))
    | `UVar (_, (_, c), _) when c <> [] ->
        Format.fprintf f "anything that is %s"
          (String.concat " and " (List.map string_of_constr c))
    (* Print the full thing, then display constraints *)
    | _ ->
        let constraints = print ~par:false DS.empty t in
        let constraints = DS.elements constraints in
        if constraints <> [] then (
          let constraints =
            List.map
              (fun (name, c) ->
                (name, String.concat " and " (List.map string_of_constr c)))
              constraints
          in
          let constraints =
            List.stable_sort (fun (_, a) (_, b) -> compare a b) constraints
          in
          let group : ('a * 'b) list -> ('a list * 'b) list = function
            | [] -> []
            | (i, c) :: l ->
                let rec group prev acc = function
                  | [] -> [(List.rev acc, prev)]
                  | (i, c) :: l ->
                      if prev = c then group c (i :: acc) l
                      else (List.rev acc, prev) :: group c [i] l
                in
                group c [i] l
          in
          let constraints = group constraints in
          let constraints =
            List.map
              (fun (ids, c) -> String.concat ", " ids ^ " is " ^ c)
              constraints
          in
          Format.fprintf f "@ @[<2>where@ ";
          Format.fprintf f "%s" (List.hd constraints);
          List.iter (fun s -> Format.fprintf f ",@ %s" s) (List.tl constraints);
          Format.fprintf f "@]")
  end;
  Format.fprintf f "@]"

let print_type f t = print f (make t)

let print_scheme f (generalized, t) =
  if !debug then
    List.iter
      (fun v ->
        print f (make ~generalized (Type.make (Var v)));
        Format.fprintf f ".")
      generalized;
  print f (make ~generalized t)

let string_of_type ?generalized t : string =
  print Format.str_formatter (make ?generalized t);
  Format.fprintf Format.str_formatter "@?";
  Format.flush_str_formatter ()

let () = Type.to_string_fun := string_of_type
let string_of_scheme (g, t) = string_of_type ~generalized:g t

type explanation = bool * Type.t * Type.t * t * t

exception Type_error of explanation

let print_type_error error_header ((flipped, ta, tb, a, b) : explanation) =
  error_header (string_of_pos_opt ta.pos);
  match b with
    | `Meth (l, ([], `Ellipsis), _, `Ellipsis) when not flipped ->
        Format.printf "this value has no method %s@." l
    | _ ->
        let inferred_pos a =
          (* TODO: can we restore this? *)
          let dpos = a.pos in
          if a.pos = dpos then ""
          else (
            match dpos with
              | None -> ""
              | Some p -> " (inferred at " ^ string_of_pos ~prefix:"" p ^ ")")
        in
        let ta, tb, a, b = if flipped then (tb, ta, b, a) else (ta, tb, a, b) in
        Format.printf "this value has type@.@[<2>  %a@]%s@ " print a
          (inferred_pos ta);
        Format.printf "but it should be a %stype of%s@.@[<2>  %a@]%s@]@."
          (if flipped then "super" else "sub")
          (match tb.pos with
            | None -> ""
            | Some p ->
                Printf.sprintf " the type of the value at %s"
                  (string_of_pos ~prefix:"" p))
          print b (inferred_pos tb)

(** {1 Documentation} *)

let doc_of_type ~generalized t =
  let margin = Format.pp_get_margin Format.str_formatter () in
  Format.pp_set_margin Format.str_formatter 58;
  Format.fprintf Format.str_formatter "%a@?"
    (fun f t -> print_scheme f (generalized, t))
    t;
  Format.pp_set_margin Format.str_formatter margin;
  Doc.trivial (Format.flush_str_formatter ())

let doc_of_meths m =
  let items = new Doc.item "" in
  List.iter
    (fun { meth = m; scheme = generalized, t; doc } ->
      let i = new Doc.item ~sort:false doc in
      i#add_subsection "type" (doc_of_type ~generalized t);
      items#add_subsection m i)
    m;
  items
