open Bencode_utils
open Lwt.Syntax

type t =
  { announce : string option
  ; info_hash : bytes
  ; piece_hashes : bytes array
  ; piece_length : int64 option
  ; length : int64 option
  ; name : string option
  }
[@@deriving show]

let build_tracker_url file peer_id port =
  let announce_url = file.announce |> Option.get in
  let query =
    [ "info_hash", [ Bytes.to_string file.info_hash ]
    ; "peer_id", [ Bytes.to_string peer_id ]; "port", [ Int.to_string port ]
    ; "uploaded", [ "0" ]; "downloaded", [ "0" ]; "compact", [ "1" ]
    ; "left", [ Int64.to_string (file.length |> Option.get) ] ]
  in
  let uri = Uri.of_string announce_url in
  Uri.add_query_params uri query
;;

let request_peers file peers port =
  let uri = build_tracker_url file peers port in
  let get_sync uri =
    let open Lwt_result.Syntax in
    Lwt_main.run
      (print_endline "Sending request...";
       let* response = Piaf.Client.Oneshot.get uri in
       if Piaf.Status.is_successful response.status
       then Piaf.Body.to_string response.body
       else (
         let message = Piaf.Status.to_string response.status in
         Lwt.return (Error (`Msg message))))
  in
  match get_sync uri with
  | Ok body ->
    let tracker_bencode = Bencode.decode (`String body) in
    let peers_string =
      Bencode_utils.bencode_to_string tracker_bencode "peers" |> Option.get
    in
    let peers_bytes = peers_string |> Bytes.of_string in
    let peers = Peers.create peers_bytes in
    (* Printf.printf "Peers: %s\n" (Peers.show peers.(0)); *)
    Result.ok peers
  | Error error ->
    let message = Piaf.Error.to_string error in
    prerr_endline ("Error: " ^ message);
    Result.error `Download_peers_error
;;

let create_with_beencode bencode_root =
  let announce = bencode_to_string bencode_root "announce" in
  let info_beencode = Bencode.dict_get bencode_root "info" |> Option.get in
  let length = bencode_to_int info_beencode "length" in
  let piece_length = bencode_to_int info_beencode "piece length" in
  let pieces = Bencode.dict_get info_beencode "pieces" |> Option.get in
  let name = bencode_to_string info_beencode "name" in
  let info_hash = sha1_of_bencode info_beencode in
  let piece_hashes = split_piece_hashes pieces in
  { announce; info_hash; piece_hashes; piece_length; length; name }
;;

let open_file input_file =
  let bencode_file = Bencode.decode (`File_path input_file) in
  create_with_beencode bencode_file
;;

let download_file output_file torrent_file =
  let random_peer = Bytes.create 20 in
  let peers = Result.get_ok (request_peers torrent_file random_peer 6881) in
  (* Download *)
  let torrent =
    Torrent.create_torrent
      peers
      random_peer
      torrent_file.info_hash
      torrent_file.piece_hashes
      torrent_file.piece_length
      torrent_file.length
      torrent_file.name
  in
  let buf = Torrent.download torrent in
  (* Write File *)
  let* out_ch = Lwt_io.open_file ~mode:Output (Option.get output_file) in
  let* () = Lwt_io.write_from_exactly out_ch buf 0 (Bytes.length buf) in
  Lwt.return ()
;;
