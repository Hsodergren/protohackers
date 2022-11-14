open Eio

module Raw_Msg = struct
  [%%cstruct type t = { typ : char; f1 : int32; f2 : int32 } [@@big_endian]]
end

module Msg = struct
  type t =
    | Insert of { time : int; price : int }
    | Query of { min : int; max : int }

  let of_raw raw =
    let f1 = Int32.to_int @@ Raw_Msg.get_t_f1 raw in
    let f2 = Int32.to_int @@ Raw_Msg.get_t_f2 raw in
    match Raw_Msg.get_t_typ raw with
    | 'I' -> Some (Insert { time = f1; price = f2 })
    | 'Q' -> Some (Query { min = f1; max = f2 })
    | _ -> None
end

let handle_conn conn =
  let msg = Cstruct.create Raw_Msg.sizeof_t in
  let ret_buf = Bytes.create 4 in
  let rec loop state =
    Flow.read_exact conn msg;
    match Msg.of_raw msg with
    | Some (Insert { time; price }) -> loop ((time, price) :: state)
    | Some (Query { min; max }) ->
        let sum, num =
          List.fold_left
            (fun (sum, num) (time, price) ->
              if time >= min && time <= max then (sum + price, num + 1)
              else (sum, num))
            (0, 0) state
        in
        let v = if num = 0 then 0 else sum / num in
        Bytes.set_int32_be ret_buf 0 (Int32.of_int v);
        Flow.copy_string (Bytes.to_string ret_buf) conn;
        loop state
    | None ->
        Flow.shutdown conn `All;
        ()
  in
  loop []

let main net =
  Switch.run (fun sw ->
      let socket =
        Net.listen ~sw ~reuse_port:true ~backlog:5 net
          (`Tcp (Net.Ipaddr.V4.any, 5000))
      in
      while true do
        Net.accept_fork ~sw socket ~on_error:(traceln "%a" Fmt.exn)
          (fun conn addr ->
            traceln "%a connected" Net.Sockaddr.pp addr;
            handle_conn conn)
      done)

let () = Eio_main.run (fun env -> main (Stdenv.net env))
