open Eio

type req = Access of string | Set of string * string

let index str c = try Some (String.index str c) with Not_found -> None

let parse string =
  match index string '=' with
  | Some i ->
      let key = String.sub string 0 i in
      let value = String.sub string (i + 1) (String.length string - i - 1) in
      Set (key, value)
  | None -> Access string

let main net =
  let table = Hashtbl.create 100 in
  Hashtbl.add table "version" "The version";
  Switch.run (fun sw ->
      let socket =
        Net.datagram_socket ~sw net (`Udp (Net.Ipaddr.V4.any, 5000))
      in
      let buf = Cstruct.create 1000 in
      while true do
        let addr, size = Net.recv socket buf in
        let str = String.sub (Cstruct.to_string buf) 0 size in
        traceln "(%d) %a -> %s" size Net.Sockaddr.pp addr str;
        match parse str with
        | Set ("version", _) -> ()
        | Set (k, v) -> Hashtbl.add table k v
        | Access k ->
            let v =
              match Hashtbl.find_opt table k with Some v -> v | None -> ""
            in
            let msg = Cstruct.of_string (Fmt.str "%s=%s" k v) in
            Net.send socket addr msg
      done)

let () = Eio_main.run (fun env -> main (Stdenv.net env))
