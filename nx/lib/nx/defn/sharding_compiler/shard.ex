defmodule Nx.Defn.ShardingCompiler.Shard do
  import Inspect.Algebra

  defstruct [
    :id,
    :axis,
    :input_id,
    :node_id,
    :start,
    :length,
    :parents,
    :debug_id,
    :from_contraction?
  ]

  def inspect(%__MODULE__{start: start, length: length}, inspect_opts)
      when is_nil(start) or is_nil(length) do
    color("Shard<>", :map, inspect_opts)
  end

  def inspect(
        %__MODULE__{
          debug_id: debug_id,
          id: id,
          axis: axis,
          start: start,
          length: length,
          input_id: input_id,
          node_id: node_id
        },
        inspect_opts
      ) do
    single_line = inspect_opts.custom_options[:single_line]
    print_axis = inspect_opts.custom_options[:print_axis]

    id_doc =
      if Application.get_env(:nx, :debug_shards) do
        "(debug_id: #{inspect(debug_id)} | id: #{inspect(id)})"
      else
        "id: #{inspect(id)}"
      end

    range_doc = "#{start}..#{start + length - 1}"
    input_id_doc = if(input_id, do: "input_id: #{inspect(input_id)}", else: "")
    node_id_doc = if(node_id, do: "node_id: #{inspect(node_id)}", else: "")

    if single_line do
      concat([
        color("Shard<", :map, inspect_opts),
        if(print_axis && axis, do: "#{axis}: ", else: ""),
        range_doc,
        " ",
        id_doc,
        input_id_doc,
        node_id_doc,
        color(">", :map, inspect_opts)
      ])
    else
      concat([
        color("Shard<", :map, inspect_opts),
        nest(
          concat([
            line(),
            if(print_axis && axis, do: "#{axis}: ", else: ""),
            range_doc,
            line(),
            id_doc,
            line(),
            input_id_doc,
            line(),
            node_id_doc
          ]),
          2
        ),
        line(),
        color(">", :map, inspect_opts)
      ])
    end
  end

  defimpl Inspect do
    def inspect(mod, opts), do: Nx.Defn.ShardingCompiler.Shard.inspect(mod, opts)
  end

  @doc """
  Config is a map of axis index or name -> slices
  """
  def from_config(tensor, config, opts \\ []) do
    input_id = opts[:input_id]
    debug_id = opts[:debug_id]

    shards =
      Map.new(config, fn
        {axis_or_name, length} ->
          axis =
            if is_atom(axis_or_name) do
              Nx.axis_index(tensor, axis_or_name)
            else
              axis_or_name
            end

          axis_size = Nx.axis_size(tensor, axis)

          {slices, checksum} =
            Enum.map_reduce(0..(axis_size - 1)//length, 0, fn start, checksum ->
              {{start, length}, checksum + length}
            end)

          if checksum != axis_size do
            raise "Shard length #{length} does not evenly divide axis #{inspect(axis_or_name)} of size #{axis_size}"
          end

          shards =
            Enum.map(slices, fn {start, length} ->
              id = make_ref()

              %__MODULE__{
                id: id,
                debug_id: debug_id,
                node_id: input_id,
                axis: axis,
                start: start,
                length: length,
                input_id: input_id,
                parents: []
              }
            end)

          {axis, shards}
      end)

    Enum.reduce(Nx.axes(tensor), shards, fn axis, shards_by_axis ->
      if Map.has_key?(shards_by_axis, axis) do
        shards_by_axis
      else
        # If no shards are given, assume a fully independent axis by default.
        # We can group shards as needed later.

        shards =
          Enum.map(0..(Nx.axis_size(tensor, axis) - 1), fn start ->
            id = make_ref()

            %__MODULE__{
              id: id,
              node_id: input_id,
              debug_id: debug_id,
              axis: axis,
              start: start,
              length: 1,
              input_id: input_id,
              parents: []
            }
          end)

        Map.put(shards_by_axis, axis, shards)
      end
    end)
  end

  def make_child_shards(shards, axis, opts \\ []) do
    opts =
      Keyword.validate!(opts, [
        :extra_parents,
        from_contraction?: false,
        keep_shard_as_parent: true
      ])

    extra_parents = opts[:extra_parents] || []
    from_contraction? = opts[:from_contraction?] == true
    keep_shard_as_parent = opts[:keep_shard_as_parent]

    Enum.map(shards, fn shard ->
      parents =
        if keep_shard_as_parent do
          [shard | extra_parents]
        else
          extra_parents
        end

      %__MODULE__{
        id: make_ref(),
        axis: axis,
        start: shard.start,
        length: shard.length,
        input_id: shard.input_id,
        debug_id: shard.debug_id && shard.debug_id <> " > child",
        parents: parents,
        from_contraction?: from_contraction?
      }
    end)
  end
end
