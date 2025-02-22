(*
 * Copyright (c) 2018-2021 Tarides <contact@tarides.com>
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

open! Import

module type Value = sig
  include Irmin.Type.S

  type hash

  val hash : t -> hash
  val magic : t -> char

  val encode_bin :
    dict:(string -> int option) ->
    offset:(hash -> int63 option) ->
    t ->
    hash ->
    (string -> unit) ->
    unit

  val decode_bin :
    dict:(int -> string option) -> hash:(int63 -> hash) -> string -> int -> t
end

module type S = sig
  include Irmin.Content_addressable.S

  val add : 'a t -> value -> key Lwt.t
  (** Overwrite [add] to work with a read-only database handler. *)

  val unsafe_add : 'a t -> key -> value -> unit Lwt.t
  (** Overwrite [unsafe_add] to work with a read-only database handler. *)

  type index

  val v :
    ?fresh:bool ->
    ?readonly:bool ->
    ?lru_size:int ->
    index:index ->
    string ->
    read t Lwt.t

  val unsafe_append :
    ensure_unique:bool -> overcommit:bool -> 'a t -> key -> value -> unit

  val unsafe_mem : 'a t -> key -> bool
  val unsafe_find : check_integrity:bool -> 'a t -> key -> value option
  val flush : ?index:bool -> ?index_merge:bool -> 'a t -> unit

  val sync : ?on_generation_change:(unit -> unit) -> 'a t -> unit
  (** syncs a readonly instance with the files on disk. The same file instance
      is shared between several pack instances. Therefore only the first pack
      instance that checks a generation change, can see it.
      [on_generation_change] is a callback for all pack instances to react to a
      generation change. *)

  val version : 'a t -> Version.t
  val generation : 'a t -> int63
  val offset : 'a t -> int63

  (** @inline *)
  include S.Checkable with type 'a t := 'a t and type key := key

  val clear_caches : 'a t -> unit
  (** [clear_cache t] clears all the in-memory caches of [t]. Persistent data
      are not removed. *)

  val clear_keep_generation : 'a t -> unit Lwt.t
end

module type Maker = sig
  type key
  type index

  (** Save multiple kind of values in the same pack file. Values will be
      distinguished using [V.magic], so they have to all be different. *)
  module Make (V : Value with type hash := key) :
    S with type key = key and type value = V.t and type index = index
end

module type Sigs = sig
  module type Value = Value
  module type S = S
  module type Maker = Maker

  module Maker
      (_ : Version.S)
      (Index : Pack_index.S)
      (K : Irmin.Hash.S with type t = Index.key) :
    Maker with type key = K.t and type index = Index.t

  module Closeable (CA : S) :
    S with type key = CA.key and type value = CA.value and type index = CA.index
end
