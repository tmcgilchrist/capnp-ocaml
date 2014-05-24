(******************************************************************************
 * capnp-ocaml
 *
 * Copyright (c) 2013-2014, Paul Pelzl
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 *  1. Redistributions of source code must retain the above copyright notice,
 *     this list of conditions and the following disclaimer.
 *
 *  2. Redistributions in binary form must reproduce the above copyright
 *     notice, this list of conditions and the following disclaimer in the
 *     documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 ******************************************************************************)

(* Management of default values for structs and lists.  These values are
   passed as a pointers to data stored in the PluginSchema message
   generated by capnpc.  We will need to make a deep copy to transfer these
   objects into a StringStorage-based message, so we can easily serialize
   the string contents right into the generated code.

   It turns out to be relatively easy to handle default values for Builder
   structs and lists, because the standard Builder behavior is to eliminate
   nulls as early as possible: default values are immediately deep copied
   into the Builder message so that the implementation can hold references
   to valid data.

   Surprisingly, the more difficult case is the Reader implementation.
   The read-only semantics imply that we can't use the same approach here:
   if there's a null pointer, a dereference must return default data
   which is physically stored in a different message.  But because we have
   functorized the code over the message type, we can't arbitrarily choose
   to return default data stored in a *string* message; we must return
   default data stored in a message type which matches the functor parameter.

   So when we instantiate the generated functor, we immediately construct
   a new message of an appropriate type and deep-copy the default values
   from string storage into this new message of the correct type.
*)


open Core.Std

module Copier = Capnp.Runtime.BuilderOps.Make(GenCommon.M)(GenCommon.M)
module DC = Capnp.Runtime.Common.Make(GenCommon.M)
module M = GenCommon.M

module Common = Capnp.Runtime.Common
let sizeof_uint64 = Common.sizeof_uint64

type t = {
  (* Message storage. *)
  message : Capnp.Message.rw M.Message.t;

  (* Array of structs which have been stored in the message, along with
     their unique identifiers. *)
  structs : (string * Capnp.Message.rw DC.StructStorage.t) Res.Array.t;

  (* Array of lists which have been stored in the message, along with
     their unique identifiers. *)
  lists : (string * Capnp.Message.rw DC.ListStorage.t) Res.Array.t;

  (* Array of pointers which have been stored in the message, along
     with their unique identifiers. *)
  pointers : (string * Capnp.Message.rw M.Slice.t) Res.Array.t;
}

type ident_t = string


let create () = {
  message  = M.Message.create 64;
  structs  = Res.Array.empty ();
  lists    = Res.Array.empty ();
  pointers = Res.Array.empty ();
}

let make_ident node_id field_name =
  "default_value_" ^ (Uint64.to_string node_id) ^ "_" ^ field_name

let builder_string_of_ident x = "_builder_" ^ x

let reader_string_of_ident x = "_reader_" ^ x


let add_struct defaults ident struct_storage =
  let open DC.StructStorage in
  let data_words    = struct_storage.data.M.Slice.len / sizeof_uint64 in
  let pointer_words = struct_storage.pointers.M.Slice.len / sizeof_uint64 in
  let struct_copy = Copier.deep_copy_struct ~src:struct_storage
      ~dest_message:defaults.message ~data_words ~pointer_words
  in
  Res.Array.add_one defaults.structs (ident, struct_copy)


let add_list defaults ident list_storage =
  let open DC.ListStorage in
  let list_copy = Copier.deep_copy_list ~src:list_storage
      ~dest_message:defaults.message ()
  in
  Res.Array.add_one defaults.lists (ident, list_copy)


let add_pointer defaults ident pointer_bytes =
  let dest = M.Slice.alloc defaults.message sizeof_uint64 in
  let () = Copier.deep_copy_pointer ~src:pointer_bytes ~dest in
  Res.Array.add_one defaults.pointers (ident, dest)


let hex_table = [|
  '0'; '1'; '2'; '3'; '4'; '5'; '6'; '7';
  '8'; '9'; 'a'; 'b'; 'c'; 'd'; 'e'; 'f';
|]

(* [String.escaped] produces valid data, but it's not the easiest to try to read
   the octal format.  Generate hex instead. *)
let make_literal s =
  let result = String.create ((String.length s) * 4) in
  for i = 0 to String.length s - 1 do
    let byte = Char.to_int s.[i] in
    let upper_nibble = (byte lsr 4) land 0xf in
    let lower_nibble = byte land 0xf in
    result.[(4 * i) + 0] <- '\\';
    result.[(4 * i) + 1] <- 'x';
    result.[(4 * i) + 2] <- hex_table.(upper_nibble);
    result.[(4 * i) + 3] <- hex_table.(lower_nibble);
  done;
  result


(* Emit a semicolon-delimited string literal, wrapping at approximately the specified
   word wrap boundary.  We use the end-of-line-backslash to emit a string literal
   which spans multiple lines.  Escaped literals for binary data can contain lots
   of backslashes, so we may stretch a line slightly to avoid breaking in the
   middle of a literal backslash. *)
let emit_literal_seg (segment : string) (wrap : int) : string list =
  let literal = make_literal segment in
  let lines = Res.Array.empty () in
  let rec loop line_start line_end =
    let () = assert (line_end  <= String.length literal) in
    if line_end = String.length literal then
      let last_line = String.sub literal line_start (line_end - line_start) in
      let () = Res.Array.add_one lines (last_line ^ "\";") in
      Res.Array.to_list lines
    else if literal.[line_end - 1] <> '\\' then
      let line = String.sub literal line_start (line_end - line_start) in
      let () = Res.Array.add_one lines (line ^ "\\") in
      loop line_end (min (line_end + wrap) (String.length literal))
    else
      loop line_start (line_end + 1)
  in
  "\"\\" :: (loop 0 (min wrap (String.length literal)))


(* Generate appropriate code for instantiating a message which contains
   all the struct and list default values. *)
let emit_instantiate_builder_message message : string list =
  let message_segment_literals =
    let strings = M.Message.to_storage message in
    (* 64 characters works out to 16 bytes per line. *)
    let wrap_chars = 64 in
    List.fold_left (List.rev strings) ~init:[] ~f:(fun acc seg ->
      (emit_literal_seg seg wrap_chars) @ acc)
  in [
    "module DefaultsMessage_ = Capnp.Runtime.Builder.DefaultsMessage";
    "module DefaultsCommon_  = Capnp.Runtime.Builder.DC";
    "";
    "let _builder_defaults_message =";
    "  let message_segments = ["; ] @
    (GenCommon.apply_indent ~indent:"    " message_segment_literals) @ [
    "  ] in";
    "  DefaultsMessage_.Message.readonly";
    "    (DefaultsMessage_.Message.of_storage message_segments)";
    "";
  ]


(* Generate code which instantiates struct descriptors for struct defaults
   stored in the message. *)
let emit_instantiate_builder_structs struct_array : string list =
  Res.Array.fold_right (fun (ident, struct_storage) acc ->
    let open DC.StructStorage in [
      "let " ^ (builder_string_of_ident ident) ^ " = {";
      "  DefaultsCommon_.StructStorage.data = {";
      "    DefaultsMessage_.Slice.msg = _builder_defaults_message;";
      "    DefaultsMessage_.Slice.segment_id = " ^
        (Int.to_string struct_storage.data.M.Slice.segment_id) ^ ";";
      "    DefaultsMessage_.Slice.start = " ^
        (Int.to_string struct_storage.data.M.Slice.start) ^ ";";
      "    DefaultsMessage_.Slice.len = " ^
        (Int.to_string struct_storage.data.M.Slice.len) ^ ";";
      "  };";
      "  DefaultsCommon_.StructStorage.pointers = {";
      "    DefaultsMessage_.Slice.msg = _builder_defaults_message;";
      "    DefaultsMessage_.Slice.segment_id = " ^
        (Int.to_string struct_storage.pointers.M.Slice.segment_id) ^ ";";
      "    DefaultsMessage_.Slice.start = " ^
        (Int.to_string struct_storage.pointers.M.Slice.start) ^ ";";
      "    DefaultsMessage_.Slice.len = " ^
        (Int.to_string struct_storage.pointers.M.Slice.len) ^ ";";
      "  };";
      "}";
      "";
    ] @ acc)
    struct_array
    []


(* Generate code which instantiates list descriptors for list defaults
   stored in the message. *)
let emit_instantiate_builder_lists list_array : string list =
  Res.Array.fold_right (fun (ident, list_storage) acc ->
    let open DC.ListStorage in [
      "let " ^ (builder_string_of_ident ident) ^ " = {";
      "  DefaultsCommon_.ListStorage.storage = {";
      "    DefaultsMessage_.Slice.msg = _builder_defaults_message;";
      "    DefaultsMessage_.Slice.segment_id = " ^
        (Int.to_string list_storage.storage.M.Slice.segment_id) ^ ";";
      "    DefaultsMessage_.Slice.start = " ^
        (Int.to_string list_storage.storage.M.Slice.start) ^ ";";
      "    DefaultsMessage_.Slice.len = " ^
        (Int.to_string list_storage.storage.M.Slice.len) ^ "; };";
      "  DefaultsCommon_.ListStorage.storage_type = Capnp.Runtime.Common. " ^
        (Common.ListStorageType.to_string list_storage.storage_type) ^ ";";
      "  DefaultsCommon_.ListStorage.num_elements = " ^
        (Int.to_string list_storage.num_elements) ^ ";";
      "}";
      "";
    ] @ acc)
    list_array
    []


(* Generate code which instantiates slices for pointer defaults
   stored in the message. *)
let emit_instantiate_builder_pointers pointer_array : string list =
  Res.Array.fold_right (fun (ident, pointer_bytes) acc -> [
      "let " ^ (builder_string_of_ident ident) ^ " = {";
      "  DefaultsMessage_.Slice.msg = _builder_defaults_message;";
      "  DefaultsMessage_.Slice.segment_id = " ^
        (Int.to_string pointer_bytes.M.Slice.segment_id) ^ ";";
      "  DefaultsMessage_.Slice.start = " ^
        (Int.to_string pointer_bytes.M.Slice.start) ^ ";";
      "  DefaultsMessage_.Slice.len = " ^
        (Int.to_string pointer_bytes.M.Slice.len) ^ ";";
      "}";
      "";
    ] @ acc)
    pointer_array
    []



let gen_builder_defaults defaults =
  (emit_instantiate_builder_message defaults.message) @
    (emit_instantiate_builder_structs defaults.structs) @
    (emit_instantiate_builder_lists defaults.lists) @
    (emit_instantiate_builder_pointers defaults.pointers)


(* Generate code for instantiating a defaults storage message
   using the same native storage type as the functor parameter. *)
let emit_instantiate_reader_message () = [
  "module DefaultsCopier_ =";
  "  Runtime.BuilderOps.Make(Runtime.Builder.DefaultsMessage)(MessageWrapper)";
  "";
  "let _reader_defaults_message =";
  "  MessageWrapper.Message.create";
  "    (DefaultsMessage_.Message.total_size _builder_defaults_message)";
  "";
]


let emit_instantiate_reader_structs struct_array =
  Res.Array.fold_left (fun acc (ident, struct_storage) -> [
      "let " ^ (reader_string_of_ident ident) ^ " =";
      "  let data_words =";
      "    let def = " ^ (builder_string_of_ident ident) ^ " in";
      "    let data_slice = def.DefaultsCommon_.StructStorage.data in";
      "    data_slice.DefaultsMessage_.Slice.len / 8";
      "  in";
      "  let pointer_words =";
      "    let def = " ^ (builder_string_of_ident ident) ^ " in";
      "    let pointers_slice = def.DefaultsCommon_.StructStorage.pointers in";
      "    pointers_slice.DefaultsMessage_.Slice.len / 8";
      "  in";
      "  DefaultsCopier_.RWC.StructStorage.readonly";
      "    (DefaultsCopier_.deep_copy_struct ~src:" ^ (builder_string_of_ident ident);
      "    ~dest_message:_reader_defaults_message ~data_words ~pointer_words)";
      "";
    ] @ acc)
    []
    struct_array


let emit_instantiate_reader_lists list_array =
  Res.Array.fold_left (fun acc (ident, list_storage) -> [
      "let " ^ (reader_string_of_ident ident) ^ " =";
      "  DefaultsCopier_.RWC.ListStorage.readonly";
      "    (DefaultsCopier_.deep_copy_list ~src:" ^ (builder_string_of_ident ident);
      "    ~dest_message:_reader_defaults_message ())";
      "";
    ] @ acc)
    []
    list_array


let emit_instantiate_reader_pointers pointer_array =
  Res.Array.fold_left (fun acc (ident, pointer_bytes) -> [
      "let " ^ (reader_string_of_ident ident) ^ " =";
      "  DefaultsMessage_.Slice.readonly";
      "    (let dest = DefaultsMessage_.Slice.alloc 8 in";
      "    let () = DefaultsCopier_.deep_copy_pointer ~src:" ^
        (builder_string_of_ident ident);
      "      ~dest";
      "    in dest)";
      "";
    ] @ acc)
    []
    pointer_array


let gen_reader_defaults defaults =
  (emit_instantiate_reader_message ()) @
    (emit_instantiate_reader_structs defaults.structs) @
    (emit_instantiate_reader_lists defaults.lists) @
    (emit_instantiate_builder_pointers defaults.pointers)

