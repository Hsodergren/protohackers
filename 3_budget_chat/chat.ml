open Eio

let welcome_message = "Welcome to the chat, what is your name?\n"

module Name : sig
  type t

  val v : string -> t option
  val to_string : t -> string
  val compare : t -> t -> int
  val pp : t Fmt.t
end = struct
  type t = string

  let v (str : string) : t option =
    match str with
    | "" -> None
    | name ->
        if
          String.for_all
            (function
              | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' -> true | _ -> false)
            name
        then Some name
        else None

  let to_string x = x
  let compare = String.compare
  let pp = Fmt.string
end

let handle_conn conn stream =
  Flow.copy_string welcome_message conn;
  let buf = Buf_read.of_flow ~max_size:1000 conn in
  let line = Buf_read.line buf in
  match Name.v line with
  | Some name ->
      Stream.add stream (`Join (name, conn));
      Buf_read.lines buf
      |> Seq.iter (fun line -> Stream.add stream (`Msg (name, line)));
      Stream.add stream (`Leave name)
  | None -> traceln "(%s) invalid name" line

let server stream =
  let module M = Map.Make (Name) in
  let send string conn =
    try Flow.copy_string string conn with Invalid_argument _ -> ()
    (* gets Invalid argument if a connection closes wile sending,
       can happen if for example two connections close at the same time *)
  in
  let rec loop state =
    let users =
      M.bindings state
      |> List.map (fun a -> Name.to_string (fst a))
      |> String.concat ", "
    in
    traceln "users = %s" users;
    match Stream.take stream with
    | `Join (name, conn) ->
        traceln "join %a" Name.pp name;
        if M.mem name state then loop state
        else
          let users =
            M.bindings state
            |> List.map (fun (n, conn) ->
                   send
                     (Fmt.str "* %s entered the room\n" (Name.to_string name))
                     conn;
                   Name.to_string n)
            |> String.concat " "
          in
          send ("* The room contains : " ^ users ^ "\n") conn;
          loop (M.add name conn state)
    | `Msg (name, msg) ->
        traceln "msg [%a] %s" Name.pp name msg;
        M.to_seq state
        |> Seq.iter (fun (n, conn) ->
               if Name.compare n name = 0 then ()
               else send (Fmt.str "[%s] %s\n" (Name.to_string name) msg) conn);
        loop state
    | `Leave name ->
        traceln "leave %a" Name.pp name;
        let state = M.remove name state in
        M.to_seq state
        |> Seq.iter (fun (_, conn) ->
               (* Fmt.pr "writing to %a%!\n" Name.pp n; *)
               send (Fmt.str "* %a left the room\n" Name.pp name) conn);
        loop state
  in
  loop M.empty

let main net =
  let msg_stream = Stream.create 10 in
  Switch.run (fun sw ->
      Fiber.fork ~sw (fun () -> server msg_stream);
      let socket =
        Net.listen ~sw ~reuse_addr:true ~backlog:5 net
          (`Tcp (Net.Ipaddr.V4.any, 5000))
      in
      while true do
        Net.accept_fork ~sw socket ~on_error:(traceln "error: %a" Fmt.exn)
          (fun conn addr ->
            traceln "connection from %a" Net.Sockaddr.pp addr;
            handle_conn conn msg_stream)
      done)

let () = Eio_main.run (fun env -> main (Stdenv.net env))
