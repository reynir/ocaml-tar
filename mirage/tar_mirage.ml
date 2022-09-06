(*
 * Copyright (C) 2015 Citrix Systems Inc.
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

(** Tar archives as read-only key=value stores for Mirage *)

open Lwt.Infix

module StringMap = Map.Make(String)

module Make_KV_RO (BLOCK : Mirage_block.S) = struct

  type entry =
    | Value of Tar.Header.t * int64
    | Dict of Tar.Header.t * entry StringMap.t

  type t = {
    b: BLOCK.t;
    mutable map: entry;
    (** offset in bytes *)
    mutable end_of_archive: int64;
    info: Mirage_block.info;
  }

  type key = Mirage_kv.Key.t

  type error = [ Mirage_kv.error | `Block of BLOCK.error ]

  let pp_error ppf = function
    | #Mirage_kv.error as e -> Mirage_kv.pp_error ppf e
    | `Block b -> BLOCK.pp_error ppf b

  let get_node t key =
    let rec find e = function
      | [] -> Ok e
      | hd::tl -> match e with
        | Value _ -> Error (`Dictionary_expected key)
        | Dict (_, m) -> match StringMap.find_opt hd m with
          | Some e -> find e tl
          | None -> Error (`Not_found key)
    in
    find t (Mirage_kv.Key.segments key)

  let exists t key =
    let r = match get_node t.map key with
      | Ok (Value _) -> Ok (Some `Value)
      | Ok (Dict _) -> Ok (Some `Dictionary)
      | Error (`Not_found _) -> Ok None
      | Error e -> Error e
    in
    Lwt.return r

  module Reader = struct
    type in_channel = {
      b: BLOCK.t;
      (** offset in bytes *)
      mutable offset: int64;
      info: Mirage_block.info;
    }
    type 'a t = 'a Lwt.t
    let really_read in_channel buffer =
      assert(Cstruct.length buffer <= 512);
      (* Tar assumes 512 byte sectors, but BLOCK might have 4096 byte sectors for example *)
      let sector_size = Int64.of_int in_channel.info.Mirage_block.sector_size in
      let sector' = Int64.(div in_channel.offset sector_size) in
      let page = Io_page.(to_cstruct @@ get 1) in
      (* However don't try to read beyond the end of the disk *)
      let total_size_bytes = Int64.(mul in_channel.info.Mirage_block.size_sectors sector_size) in
      let tmp = Cstruct.sub page 0 (min 4096 Int64.(to_int @@ (sub total_size_bytes in_channel.offset))) in
      BLOCK.read in_channel.b sector' [ tmp ]
      >>= function
      | Error e -> Lwt.fail (Failure (Format.asprintf "Failed to read sector %Ld from block device: %a" sector'
                             BLOCK.pp_error e))
      | Ok () ->
        (* If the BLOCK sector size is big, then we need to select the 512 bytes we want *)
        let offset = Int64.(to_int (sub in_channel.offset (mul sector' (of_int in_channel.info.Mirage_block.sector_size)))) in
        in_channel.offset <- Int64.(add in_channel.offset (of_int (Cstruct.length buffer)));
        Cstruct.blit page offset buffer 0 (Cstruct.length buffer);
        Lwt.return_unit
    let skip in_channel n =
      in_channel.offset <- Int64.(add in_channel.offset (of_int n));
      Lwt.return_unit
    let _get_current_tar_sector in_channel = Int64.div in_channel.offset 512L

  end
  module HR = Tar.HeaderReader(Lwt)(Reader)

  let get t key =
    match get_node t.map key with
    | Error e -> Lwt.return (Error e)
    | Ok (Dict _) -> Lwt.return (Error (`Value_expected key))
    | Ok (Value (hdr, start_sector)) ->
      BLOCK.get_info t.b >>= fun info ->
      let open Int64 in
      let sector_size = of_int info.Mirage_block.sector_size in

      (* Compute the unaligned data we need to read *)
      let start_bytes = mul start_sector 512L in
      let length_bytes = hdr.Tar.Header.file_size in
      let end_bytes = add start_bytes length_bytes in
      (* Compute the starting sector and ending sector (rounding down then up) *)
      let start_sector, start_padding = div start_bytes sector_size, rem start_bytes sector_size in
      let end_sector = div (pred (add end_bytes sector_size)) sector_size in
      let n_sectors = succ (sub end_sector start_sector) in

      let n_bytes = to_int (mul sector_size n_sectors) in
      let n_pages = (n_bytes + 4095) / 4096 in
      let block = Io_page.(to_cstruct @@ get n_pages) in
      (* Don't try to read beyond the end of the archive *)
      let total_size_bytes = Int64.(mul t.info.Mirage_block.size_sectors sector_size) in
      let tmp = Cstruct.sub block 0 (Stdlib.min (Cstruct.length block) Int64.(to_int @@ (sub total_size_bytes (mul start_sector 512L)))) in
      BLOCK.read t.b start_sector [ tmp ] >|= function
      | Error b -> Error (`Block b)
      | Ok () ->
        let buf = Cstruct.sub block (to_int start_padding) (to_int length_bytes) in
        Ok (Cstruct.to_string buf)

  let list t key =
    let r = match get_node t.map key with
      | Ok (Dict (_, m)) ->
        Ok (StringMap.fold (fun key value acc ->
            match value with
            | Dict _ -> (key, `Dictionary) :: acc
            | Value _ -> (key, `Value) :: acc)
            m [])
      | Ok (Value _) -> Error (`Dictionary_expected key)
      | Error e -> Error e
    in
    Lwt.return r

  let to_day_ps hdr =
    let ts =
      match Ptime.Span.of_float_s (Int64.to_float hdr.Tar.Header.mod_time) with
      | None -> Ptime.epoch
      | Some span -> match Ptime.add_span Ptime.epoch span with
        | None -> Ptime.epoch
        | Some ts -> ts
    in
    Ptime.(Span.to_d_ps (to_span ts))

  let last_modified t key =
    let r = match get_node t.map key with
      | Ok (Dict (hdr, _)) -> Ok (to_day_ps hdr)
      | Ok (Value (hdr, _)) -> Ok (to_day_ps hdr)
      | Error e -> Error e
    in
    Lwt.return r

  let digest t key =
    get t key >|= function
    | Error e -> Error e
    | Ok data -> Ok (Digest.string data)

  (* Compare filenames without a leading / or ./ *)
  let trim_slash x =
    let startswith prefix x =
      let prefix' = String.length prefix in
      let x' = String.length x in
      x' >= prefix' && (String.sub x 0 prefix' = prefix) in
    if startswith "./" x
    then String.sub x 2 (String.length x - 2)
    else if startswith "/" x
    then String.sub x 1 (String.length x - 1)
    else x

  let is_dict filename =
    String.get filename (pred (String.length filename)) = '/'

  let insert map key value =
    let rec go m = function
      | [] -> assert false
      | [hd] -> StringMap.add hd value m
      | hd::tl ->
        let hdr, m' = match StringMap.find_opt hd m with
          | None -> Tar.Header.make hd 0L, StringMap.empty
          | Some (Value _) -> assert false
          | Some (Dict (hdr, m)) -> hdr, m
        in
        let m'' = go m' tl in
        StringMap.add hd (Dict (hdr, m'')) m
    in
    go map (Mirage_kv.Key.segments key)

  let connect b =
    BLOCK.get_info b >>= fun info ->
    let in_channel = { Reader.b; offset = 0L; info } in
    let rec loop map =
      HR.read in_channel >>= function
      | Error `Eof -> Lwt.return map
      | Ok tar ->
        let filename = trim_slash tar.Tar.Header.file_name in
        let data_tar_offset = Int64.div in_channel.Reader.offset 512L in
        let v_or_d = if is_dict filename then Dict (tar, StringMap.empty) else Value (tar, data_tar_offset) in
        let map = insert map (Mirage_kv.Key.v filename) v_or_d in
        Reader.skip in_channel (Int64.to_int tar.Tar.Header.file_size) >>= fun () ->
        Reader.skip in_channel (Tar.Header.compute_zero_padding_length tar) >>= fun () ->
        loop map in
    let root = StringMap.empty in
    loop root >>= fun map ->
    (* This is after the two [zero_block]s *)
    let end_of_archive = in_channel.Reader.offset in
    let map = Dict (Tar.Header.make "/" 0L, map) in
    Lwt.return ({ b; map; info; end_of_archive })

  let disconnect _ = Lwt.return_unit

end


module Make_KV_RW (BLOCK : Mirage_block.S) = struct

  include Make_KV_RO(BLOCK)

  let free t =
    Int64.(sub (mul (of_int t.info.sector_size) t.info.size_sectors)
             t.end_of_archive)

  let is_safe_to_set t key =
    let rec find e path =
      match e, path with
      | (Value _ | Dict _), [] -> Error `Entry_already_exists
      | Value _, _hd :: _tl -> Error `Path_segment_is_a_value
      | Dict (_, m), hd :: tl ->
        match StringMap.find_opt hd m with
        | Some e -> find e tl
        | None ->
          (* if either (part of) the path or the file doesn't exist we're good *)
          Ok ()
    in
    find t.map (Mirage_kv.Key.segments key)

  let header_of_key key len =
    Tar.Header.make (Mirage_kv.Key.to_string key) (Int64.of_int len)

  let space_needed header =
    let header_size = Tar.Header.length in
    let data_size = header.Tar.Header.file_size in
    let padding_size = Tar.Header.compute_zero_padding_length header in
    Int64.(add (of_int header_size) (add (of_int padding_size) data_size))

  let update_insert map key hdr offset =
    match map with
    | Value _ -> assert false
    | Dict (root, map) ->
      let map = insert map key (Value (hdr, offset)) in
      Dict (root, map)

  module Writer = struct
    type out_channel = {
      b: BLOCK.t;
      (** offset in bytes *)
      mutable offset: int64;
      info: Mirage_block.info;
    }
    type 'a t = 'a Lwt.t
    let really_write out_channel data =
      assert (Cstruct.length data <= 512);
      let data = Cstruct.(append data (create (length data - 512))) in
      let sector = Int64.(div out_channel.offset (of_int out_channel.info.sector_size)) in
      BLOCK.write out_channel.b sector [ data ] >>= function
      | Ok () ->
        out_channel.offset <- Int64.add out_channel.offset 512L;
        Lwt.return_unit
      | Error e -> Lwt.fail (Failure (Format.asprintf "Failed to write sector %Ld to block device: %a"
                             sector BLOCK.pp_write_error e))
  end
  module HW = Tar.HeaderWriter(Lwt)(Writer)

  type write_error = [ `Block of BLOCK.write_error | Mirage_kv.write_error | `Entry_already_exists | `Path_segment_is_a_value | `Append_only ]

  let pp_write_error ppf = function
   | `Block e -> BLOCK.pp_write_error ppf e
   | #Mirage_kv.write_error as e -> Mirage_kv.pp_write_error ppf e
   | `Entry_already_exists -> Fmt.string ppf "entry already exists"
   | `Path_segment_is_a_value -> Fmt.string ppf "path segment is a value"
   | `Append_only -> Fmt.string ppf "append only"

  let set t key data =
    let data = Cstruct.of_string data in
    let ( >>>= ) = Lwt_result.bind in
    let r =
      let ( let* ) = Result.bind in
      let* () = is_safe_to_set t key in
      let hdr = header_of_key key (Cstruct.length data) in
      let space_needed = space_needed hdr in
      let* () = if free t >= space_needed then Ok () else Error `No_space in
      Ok (hdr, space_needed)
    in
    Lwt.return r >>>= fun (hdr, space_needed) ->
    let open Int64 in
    let sector_size = of_int t.info.Mirage_block.sector_size in

    let start_bytes = sub t.end_of_archive (mul 2L 512L) in
    let end_bytes = add start_bytes space_needed in
    (* Compute the starting sector and ending sector (rounding down then up) *)
    let start_sector, _start_sector_offset = div start_bytes sector_size, rem start_bytes sector_size in
    let end_sector = div (pred (add end_bytes sector_size)) sector_size in

    t.end_of_archive <- add t.end_of_archive space_needed;

    Lwt_result.map_err (fun e -> `Block e)
      (BLOCK.write t.b end_sector [ Tar.Header.zero_block ]) >>>= fun () ->
    Lwt_result.map_err (fun e -> `Block e)
      (BLOCK.write t.b (add end_sector 1L) [ Tar.Header.zero_block ]) >>>= fun () ->
    let rec write_one sec data =
      if sec = end_sector then
        Lwt.return (Ok ())
      else
        let block, rest = Cstruct.split data 512 in
        Lwt_result.map_err (fun e -> `Block e)
          (BLOCK.write t.b sec [ block ]) >>>= fun () ->
        write_one (succ sec) rest
    in
    let hw = Writer.{ b = t.b ; offset = start_bytes ; info = t.info } in
    HW.write ~level:Tar.Header.Ustar hdr hw >>= fun () ->
    let pad = Tar.Header.compute_zero_padding_length hdr in
    write_one (succ start_sector) (Cstruct.append data (Cstruct.create pad)) >>>= fun () ->
    t.map <- update_insert t.map key hdr (succ start_sector);
    Lwt.return (Ok ())

  let remove _ _ =
    Lwt.return (Error `Append_only)

  let batch t ?retries:_ f = f t

end
