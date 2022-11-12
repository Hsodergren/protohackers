open Eio.Std

let is_prime n =
  let exception NonPrime in
  let aux () =
    let top = Float.sqrt (float n) |> Float.ceil |> Int.of_float in
    for v = 1 to top do
      if n mod ((v * 2) + 1) = 0 then raise NonPrime
    done;
    true
  in
  if n < 2 then false
  else if n = 2 || n = 3 then true
  else if n mod 2 = 0 || n mod 3 = 0 then false
  else try aux () with NonPrime -> false

let parse_request string =
  let module J = Yojson.Safe in
  let json = J.from_string string in
  match J.Util.member "method" json with
  | `String "isPrime" -> (
      match J.Util.member "number" json with
      | `Int n -> `Int n
      | `Intlit _ -> `NonInt
      | `Float _ -> `NonInt
      | _ -> `Malformed)
  | _ -> `Malformed

let response prime =
  (`Assoc [ ("method", `String "isPrime"); ("prime", `Bool prime) ]
  |> Yojson.Safe.to_string)
  ^ "\n"

let main net =
  let module N = Eio.Net in
  let exception Malformed of string in
  Eio.Switch.run (fun sw ->
      let listen =
        N.listen net ~reuse_addr:true ~sw ~backlog:5
          (`Tcp (N.Ipaddr.V4.any, 5000))
      in
      while true do
        N.accept_fork ~sw listen
          ~on_error:(fun exn -> traceln "ERROR: %a" Fmt.exn exn)
          (fun conn addr ->
            traceln "%a" N.Sockaddr.pp addr;
            let buf = Eio.Buf_read.of_flow ~max_size:1_000_000 conn in
            Eio.Buf_read.lines buf
            |> Seq.iter (fun line ->
                   try
                     traceln "%s" line;
                     match parse_request line with
                     | `Int n ->
                         Eio.Flow.copy_string (response (is_prime n)) conn
                     | `NonInt -> Eio.Flow.copy_string (response false) conn
                     | `Malformed ->
                         Eio.Flow.copy_string "malformed" conn;
                         raise (Malformed line)
                   with Malformed line | Yojson.Json_error line ->
                     traceln "got malformed request %s" line;
                     Eio.Flow.copy_string "malformed" conn;
                     conn#shutdown `All))
      done)

let () =
  Eio_main.run (fun env ->
      let open Eio.Stdenv in
      main (net env))
