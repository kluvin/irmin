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

(** Trace file construction.

    This file is meant to be used from Tezos. OCaml version 4.09 and the 32bit
    architecture should be supported.

    A module [Make_replayable] has yet to be implemented. *)

open Lwt.Syntax

(** Make state trace collector. *)
module Make_stat (Store : Irmin.KV) = struct
  module Def = Trace_definitions.Stat_trace

  type t = {
    writer : Def.writer;
    store_path : string;
    mutable t0 : Mtime_clock.counter;
    mutable prev_nb_merge : int option;
    mutable commit_before : Def.bag_of_stats * Def.store_before;
  }
  (** Imperative stat trace collector. It is optimised to minimise the CPU
      footprint. *)

  module Bag_of_stats = struct
    let pack () =
      let open Irmin_pack.Stats in
      let v = get () in
      Def.
        {
          finds = v.finds;
          cache_misses = v.cache_misses;
          appended_hashes = v.appended_hashes;
          appended_offsets = v.appended_offsets;
        }

    let tree () =
      let open Store.Tree in
      let v = counters () in
      Def.
        {
          contents_hash = v.contents_hash;
          contents_find = v.contents_find;
          contents_add = v.contents_add;
          node_hash = v.node_hash;
          node_mem = v.node_mem;
          node_add = v.node_add;
          node_find = v.node_find;
          node_val_v = v.node_val_v;
          node_val_find = v.node_val_find;
          node_val_list = v.node_val_list;
        }

    let index prev_nb_merge =
      let open Index.Stats in
      let v = get () in
      let new_merge_durations =
        match prev_nb_merge with
        | None -> []
        | Some prev_nb_merge ->
            let nb_merge = v.nb_merge in
            let merge_durations = v.merge_durations in
            (* Only the latest merge durations are remembered in
               [merge_durations] *)
            let merge_durations_idx0 =
              max 0 (nb_merge - List.length merge_durations)
            in
            let rec aux merge_idx =
              if merge_idx >= nb_merge then []
              else if merge_idx < merge_durations_idx0 then
                Float.nan :: aux (merge_idx + 1)
              else
                let i = merge_idx - merge_durations_idx0 in
                List.nth merge_durations i :: aux (merge_idx + 1)
            in
            let l = aux prev_nb_merge in
            assert (prev_nb_merge + List.length l = nb_merge);
            l
      in
      let new_merge_durations =
        List.map (fun v -> v /. 1e6) new_merge_durations
      in
      Def.
        {
          bytes_read = v.bytes_read;
          nb_reads = v.nb_reads;
          bytes_written = v.bytes_written;
          nb_writes = v.nb_writes;
          nb_merge = v.nb_merge;
          new_merge_durations;
        }

    let gc () =
      let open Gc in
      let v = quick_stat () in
      Def.
        {
          minor_words = v.minor_words;
          promoted_words = v.promoted_words;
          major_words = v.major_words;
          minor_collections = v.minor_collections;
          major_collections = v.major_collections;
          heap_words = v.heap_words;
          compactions = v.compactions;
          top_heap_words = v.top_heap_words;
          stack_size = v.stack_size;
        }

    let size_of_file path =
      let open Unix.LargeFile in
      try (stat path).st_size with Unix.Unix_error _ -> 0L

    let disk store_path =
      let ( / ) left right = Filename.concat left right in
      Def.
        {
          index_data = store_path / "index" / "data" |> size_of_file;
          index_log = store_path / "index" / "log" |> size_of_file;
          index_log_async = store_path / "index" / "log_async" |> size_of_file;
          store_dict = store_path / "store.dict" |> size_of_file;
          store_pack = store_path / "store.pack" |> size_of_file;
        }

    let now () =
      Mtime_clock.now ()
      |> Mtime.to_uint64_ns
      |> Int64.to_float
      |> ( *. ) Mtime.ns_to_s

    let create store_path prev_nb_merge =
      Def.
        {
          pack = pack ();
          tree = tree ();
          index = index prev_nb_merge;
          gc = gc ();
          disk = disk store_path;
          timestamp_wall = now ();
          timestamp_cpu = Sys.time ();
        }
  end

  let create_file : string -> Def.config -> string -> t =
   fun path config store_path ->
    let header =
      Def.
        {
          config;
          hostname = Unix.gethostname ();
          word_size = Sys.word_size;
          timeofday = Unix.gettimeofday ();
          initial_stats = Bag_of_stats.create store_path None;
        }
    in
    let dummy_commit_before =
      ( header.initial_stats,
        Def.{ nodes = 0; leafs = 0; skips = 0; depth = 0; width = 0 } )
    in
    {
      writer = Def.create_file path header;
      store_path;
      t0 = Mtime_clock.counter ();
      prev_nb_merge = Some header.initial_stats.index.nb_merge;
      commit_before = dummy_commit_before;
    }

  let flush { writer; _ } = Def.flush writer
  let close { writer; _ } = Def.close writer
  let remove { writer; _ } = Def.remove writer
  let short_op_begin t = t.t0 <- Mtime_clock.counter ()

  let short_op_end { t0; writer; _ } short_op =
    let duration =
      Mtime_clock.count t0 |> Mtime.Span.to_s |> Int32.bits_of_float
    in
    let op =
      match short_op with
      | `Add -> `Add duration
      | `Remove -> `Remove duration
      | `Find -> `Find duration
      | `Mem -> `Mem duration
      | `Mem_tree -> `Mem_tree duration
      | `Checkout -> `Checkout duration
      | `Copy -> `Copy duration
    in
    Def.append_row writer op

  let create_store_before tree =
    let+ Store.Tree.{ nodes; leafs; skips; depth; width } =
      Store.Tree.stats ~force:false tree
    in
    Def.{ nodes; leafs; skips; depth; width }

  let create_store_after tree =
    let* watched_nodes_length =
      Lwt_list.map_s
        (fun (_, steps) ->
          let* tree = Store.Tree.find_tree tree steps in
          match tree with
          | None -> Lwt.return 0
          | Some tree -> (
              match Store.Tree.destruct tree with
              | `Node tree ->
                  let* length = Store.Tree.length tree in
                  Lwt.return length
              | `Contents _ -> Lwt.return 0))
        Def.step_list_per_watched_node
    in
    Lwt.return Def.{ watched_nodes_length }

  let commit_begin t tree =
    short_op_begin t;
    let stats_before = Bag_of_stats.create t.store_path t.prev_nb_merge in
    t.prev_nb_merge <- Some stats_before.index.nb_merge;
    let+ store_before = create_store_before tree in
    t.commit_before <- (stats_before, store_before)

  let commit_end t tree =
    let duration = Mtime_clock.count t.t0 |> Mtime.Span.to_s in
    let duration = duration |> Int32.bits_of_float in
    let stats_after = Bag_of_stats.create t.store_path t.prev_nb_merge in
    t.prev_nb_merge <- Some stats_after.index.nb_merge;
    let+ store_after = create_store_after tree in
    let op =
      `Commit
        Def.
          {
            duration;
            before = fst t.commit_before;
            after = stats_after;
            store_before = snd t.commit_before;
            store_after;
          }
    in
    Def.append_row t.writer op
end
