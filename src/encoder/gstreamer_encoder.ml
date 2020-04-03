(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2019 Savonet team

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

(** GStreamer encoder *)

open Gstreamer_format
module GU = Gstreamer_utils
module Img = Image.RGBA32

let log = Log.make ["encoder"; "gstreamer"]

type gst = {
  bin : Gstreamer.Pipeline.t;
  audio_src : Gstreamer.App_src.t option;
  video_src : Gstreamer.App_src.t option;
  sink : Gstreamer.App_sink.t;
}

let encoder ext =
  let channels = Gstreamer_format.audio_channels ext in
  let mutex = Mutex.create () in
  (* Here "samples" are the number of buffers available in the GStreamer
     appsink *)
  let samples = ref 0 in
  let decr_samples = Tutils.mutexify mutex (fun () -> decr samples) in
  let incr_samples = Tutils.mutexify mutex (fun () -> incr samples) in
  let on_sample () = incr_samples () in

  let gst =
    let pipeline =
      match ext.pipeline with
        | Some p -> p
        | None ->
            let muxer =
              if ext.audio <> None && ext.video <> None then "muxer." else ""
            in
            let audio_pipeline =
              Utils.maybe
                (fun pipeline ->
                  Printf.sprintf "%s ! queue ! %s ! %s ! %s"
                    (GU.Pipeline.audio_src ~channels ~block:true "audio_src")
                    (GU.Pipeline.convert_audio ())
                    pipeline muxer)
                ext.audio
            in
            let video_pipeline =
              Utils.maybe
                (fun pipeline ->
                  Printf.sprintf "%s ! queue ! %s ! %s ! %s"
                    (GU.Pipeline.video_src ~block:true "video_src")
                    (GU.Pipeline.convert_video ())
                    pipeline muxer)
                ext.video
            in
            let muxer_pipeline =
              match ext.muxer with
                | Some muxer -> Printf.sprintf "%s name=muxer !" muxer
                | None -> ""
            in
            Printf.sprintf
              "%s %s %s appsink name=sink sync=false emit-signals=true"
              (Utils.some_or "" audio_pipeline)
              (Utils.some_or "" video_pipeline)
              muxer_pipeline
    in
    log#f ext.log "Gstreamer encoder pipeline: %s" pipeline;
    let bin = Gstreamer.Pipeline.parse_launch pipeline in
    let audio_src =
      try
        Some
          (Gstreamer.App_src.of_element
             (Gstreamer.Bin.get_by_name bin "audio_src"))
      with Not_found -> None
    in
    let video_src =
      try
        Some
          (Gstreamer.App_src.of_element
             (Gstreamer.Bin.get_by_name bin "video_src"))
      with Not_found -> None
    in
    let sink =
      Gstreamer.App_sink.of_element (Gstreamer.Bin.get_by_name bin "sink")
    in
    Gstreamer.App_sink.on_new_sample sink on_sample;
    ignore (Gstreamer.Element.set_state bin Gstreamer.Element.State_playing);
    { bin; audio_src; video_src; sink }
  in

  let stop () =
    let ret =
      if !samples > 0 then begin
        Utils.maydo Gstreamer.App_src.end_of_stream gst.audio_src;
        Utils.maydo Gstreamer.App_src.end_of_stream gst.video_src;
        GU.flush ~log gst.bin;
        let buf = Buffer.create 1024 in
        begin
          try
            while true do
              Buffer.add_string buf
                (Gstreamer.App_sink.pull_buffer_string gst.sink)
            done
          with Gstreamer.End_of_stream -> ()
        end;
        Buffer.contents buf
      end
      else ""
    in
    ignore (Gstreamer.Element.set_state gst.bin Gstreamer.Element.State_null);
    GU.flush ~log gst.bin;
    ret
  in

  let insert_metadata m =
    let m = Meta_format.to_metadata m in
    try
      let meta =
        Gstreamer.Tag_setter.of_element
          (Gstreamer.Bin.get_by_name gst.bin ext.metadata)
      in
      Hashtbl.iter
        (Gstreamer.Tag_setter.add_tag meta Gstreamer.Tag_setter.Replace)
        m;
      GU.flush ~log gst.bin
    with Not_found -> ()
  in

  let presentation_time = ref Int64.zero in
  let nano = 1_000_000_000. in
  let vduration = Int64.of_float (Frame.seconds_of_video 1 *. nano) in

  let encode frame start len =
    let duration = Int64.of_float (Frame.seconds_of_master len *. nano) in
    let videochans = if gst.video_src <> None then 1 else 0 in
    let content =
      Frame.content_of_type frame start
        { Frame.audio = channels; video = videochans; midi = 0 }
    in
    if channels > 0 then begin
      (* Put audio. *)
      let astart = Frame.audio_of_master start in
      let alen = Frame.audio_of_master len in
      let pcm = content.Frame.audio in
      let data = Bytes.create (2 * channels * alen) in
      Audio.S16LE.of_audio pcm astart data 0 alen;
      Gstreamer.App_src.push_buffer_bytes ~presentation_time:!presentation_time
        ~duration
        (Utils.get_some gst.audio_src)
        data 0 (Bytes.length data)
    end;
    if videochans > 0 then begin
      (* Put video. *)
      let vbuf = content.Frame.video in
      let vbuf = vbuf.(0) in
      let vstart = Frame.video_of_master start in
      let vlen = Frame.video_of_master len in
      for i = vstart to vstart + vlen - 1 do
        let data = Img.data vbuf.(i) in
        let presentation_time =
          Int64.add !presentation_time (Int64.mul (Int64.of_int i) vduration)
        in
        Gstreamer.App_src.push_buffer_data ~presentation_time
          ~duration:vduration
          (Utils.get_some gst.video_src)
          data 0 (Bigarray.Array1.dim data)
      done
    end;
    GU.flush ~log gst.bin;
    (* Return result. *)
    presentation_time := Int64.add !presentation_time duration;
    if !samples = 0 then ""
    else (
      let ans = Gstreamer.App_sink.pull_buffer_string gst.sink in
      decr_samples ();
      ans )
  in

  { Encoder.insert_metadata; header = None; encode; stop }

let () =
  Encoder.plug#register "GSTREAMER" (function
    | Encoder.GStreamer params ->
        let f _ m =
          let encoder = encoder params in
          encoder.Encoder.insert_metadata m;
          encoder
        in
        Some f
    | _ -> None)
