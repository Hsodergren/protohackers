open Eio

type ticket = {
  plate : string;
  road : int;
  mile1 : int;
  timestamp1 : int;
  mile2 : int;
  timestamp2 : int;
  speed : int;
}

type camera = { road : int; mile : int; limit : int }
type plate = { plate : string; timestamp : int }
type response = Err of string | Ticket of ticket | Heartbeat

type request =
  | WantHeartbeat of int
  | Plate of plate
  | IAmDispatcher of int list
  | IAmCamera of camera

module Parser = struct
  open Buf_read.Syntax

  let ( >>| ) a b = Buf_read.map b a

  let buf n =
    let+ s = Buf_read.take n in
    String.to_bytes s

  let u8 = Buf_read.any_char >>| Char.code
  let u16 = buf 2 >>| fun b -> Bytes.get_uint16_be b 0
  let u32 = buf 4 >>| fun b -> Bytes.get_int32_be b 0 |> Int32.to_int

  let str =
    let* len = u8 in
    Buf_read.take len

  let rec take_n n p =
    let* hd = p in
    let+ tl = take_n (n - 1) p in
    hd :: tl

  let request =
    let* char = u8 in
    match char with
    | 0x20 ->
        let* plate = str in
        let+ timestamp = u32 in
        Some (Plate { plate; timestamp })
    | 0x40 ->
        let+ interval = u32 in
        Some (WantHeartbeat interval)
    | 0x80 ->
        let* road = u16 in
        let* mile = u16 in
        let+ limit = u16 in
        Some (IAmCamera { road; mile; limit })
    | 0x81 ->
        let* numroads = u8 in
        let+ roads = take_n numroads u16 in
        Some (IAmDispatcher roads)
    | _ -> Buf_read.return None
end

module Writer = struct
  let ( >> ) f1 f2 buf =
    f1 buf;
    f2 buf

  let u8 int buf = Buf_write.uint8 buf int
  let u16 int buf = Buf_write.BE.uint16 buf int
  let u32 int buf = Buf_write.BE.uint32 buf (Int32.of_int int)

  let str string buf =
    Buf_write.uint8 buf (String.length string);
    Buf_write.string buf string

  let write resp buf =
    (match resp with
    | Err s -> u8 0x10 >> str s
    | Ticket { plate; road; mile1; timestamp1; mile2; timestamp2; speed } ->
        u8 0x21 >> str plate >> u16 road >> u16 mile1 >> u32 timestamp1
        >> u16 mile2 >> u32 timestamp2 >> u16 speed
    | Heartbeat -> u8 0x41)
      buf;
    Buf_write.flush buf
end

module SMap = Map.Make (String)
module IMap = Map.Make (Int)

let next_id =
  let id = ref 0 in
  fun () ->
    id := !id + 1;
    !id

type state = {
  cars : int SMap.t;
  cameras : camera IMap.t;
  dispatchers : (int * ticket Stream.t) list IMap.t;
}

let server chan () =
  let rec loop state =
    let state =
      match Stream.take chan with
      | `Plate (camera_id, (plate : plate)) -> (
          match SMap.find_opt plate.plate state.cars with
          | None ->
              { state with cars = SMap.add plate.plate camera_id state.cars }
          | Some _ -> state)
      | `Register_Camera (id, camera) ->
          { state with cameras = IMap.add id camera state.cameras }
      | `Unregister_Camera id ->
          { state with cameras = IMap.remove id state.cameras }
      | `Register_Dispatcher (id, roads, stream) ->
          traceln "dispatcher register %d" id;
          let dispatchers =
            List.fold_left
              (fun dispatchers road ->
                IMap.update road
                  (function
                    | Some l -> Some ((id, stream) :: l)
                    | None -> Some [ (id, stream) ])
                  dispatchers)
              state.dispatchers roads
          in
          { state with dispatchers }
      | `Unregister_Dispatcher rem_id ->
          traceln "dispatcher unregister %d" rem_id;
          let dispatchers =
            IMap.fold
              (fun key value acc ->
                match List.filter (fun (id, _) -> id <> rem_id) value with
                | [] -> acc
                | l -> IMap.add key l acc)
              IMap.empty state.dispatchers
          in
          { state with dispatchers }
    in
    loop state
  in
  loop { cars = SMap.empty; cameras = IMap.empty; dispatchers = IMap.empty }

let handle_conn chan conn clock =
  Switch.run (fun sw ->
      let buf_read = Buf_read.of_flow ~max_size:1024 conn in
      let hb_started = ref false in
      let returned = ref false in
      let rec hb_loop time () =
        if !returned then (
          Time.sleep clock time;
          try
            Buf_write.with_flow conn (Writer.write Heartbeat);
            hb_loop time ()
          with exn -> traceln "hb_loop write failed: %a" Fmt.exn exn)
      in
      let error msg = Buf_write.with_flow conn (Writer.write (Err msg)) in
      let handle_heartbeat i f =
        if !hb_started then error "Multiple WantHeartbeat requests"
        else (
          hb_started := true;
          Fiber.fork ~sw (hb_loop (Int.to_float i /. 10.));
          f ())
      in
      let dispatcher roads =
        let tickets = Stream.create 1 in
        let id = next_id () in
        Stream.add chan (`Register_Dispatcher (id, roads, tickets));
        let rec loop () =
          match Parser.request buf_read with
          | None -> error "invalid request"
          | Some (Plate _) -> error "plate request is only valid for cameras"
          | Some (WantHeartbeat i) -> handle_heartbeat i loop
          | Some (IAmCamera _) | Some (IAmDispatcher _) ->
              error "got IAM request while dispatcher"
        in
        let rec ticket () =
          let t = Stream.take tickets in
          Buf_write.with_flow conn (Writer.write (Ticket t));
          ticket ()
        in
        Fiber.first loop ticket;
        Stream.add chan (`Unregister_Dispatcher id)
      in
      let rec camera cam =
        let id = next_id () in
        Stream.add chan (`Register_Camera (id, cam));
        let rec loop () =
          match Parser.request buf_read with
          | None -> error "invalid request"
          | Some (Plate p) ->
              Stream.add chan (`Plate (id, p));
              loop ()
          | Some (WantHeartbeat i) -> handle_heartbeat i loop
          | Some (IAmCamera _) | Some (IAmDispatcher _) ->
              error "got IAM request while camera"
        in
        loop ();
        Stream.add chan (`Unregister_Camera id)
      in
      let rec loop () =
        match Parser.request buf_read with
        | None | Some (Plate _) -> error "Invalid request"
        | Some (WantHeartbeat i) -> handle_heartbeat i loop
        | Some (IAmCamera cam) -> camera cam
        | Some (IAmDispatcher roads) -> dispatcher roads
      in
      loop ();
      Flow.shutdown conn `All)

let main net clock =
  Switch.run (fun sw ->
      let request_channel = Stream.create max_int in
      Fiber.fork ~sw (server request_channel);
      let socket =
        Net.listen ~sw net ~backlog:5 ~reuse_addr:true
          (`Tcp (Net.Ipaddr.V4.any, 5000))
      in
      while true do
        Net.accept_fork ~sw socket ~on_error:(traceln "%a" Fmt.exn)
          (fun conn addr ->
            traceln "%a" Net.Sockaddr.pp addr;
            handle_conn request_channel conn clock)
      done)

let () = Eio_main.run (fun env -> main (Stdenv.net env) (Stdenv.clock env))
