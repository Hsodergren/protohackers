open Eio

let server_addr, server_port = ("chat.protohackers.com", 16963)
let tony = "7YWHMfk9JZe0LM0g1ZauHuiSxhI"

let is_token str =
  if
    String.length str >= 26 && String.length str <= 35 && String.get str 0 = '7'
  then tony
  else str

let parse_msg str =
  String.split_on_char ' ' str
  |> List.map (fun w -> is_token w)
  |> String.concat " "

let rewrite ~src ~dst () =
  Buf_read.lines src
  |> Seq.iter (fun l ->
         if Buf_read.eof_seen src then ()
         else
           let msg = parse_msg l in
           if l <> msg then traceln "%s -> %s" l msg else traceln "%s" l;
           Flow.copy_string (msg ^ "\n") dst);
  Flow.shutdown dst `All

let handle_conn ~sw net =
  let addrs = Net.getaddrinfo_stream net server_addr in
  List.iter (fun a -> traceln "%a" Net.Sockaddr.pp a) addrs;
  match addrs with
  | `Tcp (ip, _) :: _ ->
      fun conn ->
        let server_conn = Net.connect ~sw net (`Tcp (ip, server_port)) in
        let conn_buf = Buf_read.of_flow conn ~max_size:1_000_000 in
        let server_buf = Buf_read.of_flow server_conn ~max_size:1_000_000 in
        Fiber.both
          (rewrite ~src:conn_buf ~dst:server_conn)
          (rewrite ~src:server_buf ~dst:conn);
        traceln "both closed"
  | _ -> failwith ("cannot find " ^ server_addr)

let main net =
  Switch.run (fun sw ->
      let socket =
        Net.listen net ~sw ~backlog:5 ~reuse_addr:true
          (`Tcp (Net.Ipaddr.V4.any, 5000))
      in
      let handle_f = handle_conn ~sw net in
      while true do
        Net.accept_fork ~sw socket ~on_error:(Fmt.pr "%a" Fmt.exn)
          (fun conn addr ->
            traceln "connection from %a" Net.Sockaddr.pp addr;
            handle_f conn)
      done)

let () = Eio_main.run (fun env -> main @@ Stdenv.net env)
