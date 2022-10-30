open Eio.Std

let main net =
  Eio.Switch.run @@ fun sw ->
  let socket =
    Eio.Net.listen ~backlog:10 ~sw net (`Tcp (Eio.Net.Ipaddr.V4.any, 5000))
  in
  while true do
    Eio.Net.accept_fork ~sw socket
      ~on_error:(fun exn -> traceln "error %a" Fmt.exn exn)
      (fun conn addr ->
        traceln "connection from %a" Eio.Net.Sockaddr.pp addr;
        Eio.Flow.copy conn conn)
  done

let () = Eio_main.run (fun env -> main (Eio.Stdenv.net env))
