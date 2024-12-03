defmodule Nx.Defn.ShardingCompiler do
  alias Nx.Tensor, as: T
  alias Nx.Defn.Expr

  alias Nx.Defn.ShardingCompiler.Shard

  alias Nx.Defn.ShardingCompiler.Passes.ShardPropagation
  alias Nx.Defn.ShardingCompiler.Passes.GraphSplitter
  alias Nx.Defn.ShardingCompiler.ShardExecution
  @behaviour Nx.Defn.Compiler

  @impl true
  def __jit__(key, vars, fun, args, opts) do
    __compile__(key, vars, fun, opts).(args)
  end

  @impl true
  def __compile__(_key, vars, fun, opts) do
    opts =
      Keyword.validate!(opts, [
        :sharding_config,
        timeout: :infinity,
        sharding_compiler: Nx.Defn.Evaluator,
        sharding_compiler_options: []
      ])

    {ans, sharded_expr, expr_shards} =
      case propagate_shards(vars, fun, opts[:sharding_config]) do
        {%T{data: %ShardPropagation{expr: sharded_expr}} = ans, expr_shards} ->
          {ans, sharded_expr, expr_shards}

        {expr, shards} ->
          {expr, expr.data, shards}
      end

    {[first_stage | _] = stages, _cache, state} =
      GraphSplitter.traverse(%T{ans | data: sharded_expr}, expr_shards)

    dbg({state.args, first_stage.arguments})

    fn [args] ->
      # use task here so that we don't pollute the caller with the output collector message
      task =
        Task.async(fn ->
          args_by_idx = Enum.with_index(args, fn arg, idx -> {idx, arg} end) |> Map.new()

          Enum.flat_map(state.args, fn
            {id, {nil, idx}} ->
              start_argument_shard_providers(id, idx, args_by_idx[idx], expr_shards[id])

            _ ->
              []
          end)

          last_stage =
            for stage <- stages, reduce: nil do
              _ ->
                {:ok, _pid} = ShardExecution.Supervisor.start_link(stage)
                stage
            end

          {:ok, output_collector_pid} =
            ShardExecution.OutputCollector.start_link(ans, last_stage.id, self())

          receive do
            {ShardExecution.OutputCollector, :done, ^output_collector_pid, result} ->
              [result]
          end
        end)

      Task.await(task, opts[:timeout])
    end
  end

  defp start_argument_shard_providers(argument_id, argument_idx, arg_data, nil) do
    [
      ShardExecution.ArgumentProvider.start_link([
        arg_data.(),
        argument_idx,
        {:unsharded, argument_id}
      ])
    ]
  end

  defp start_argument_shard_providers(_arg_id, arg_idx, arg_data, %ShardPropagation{
         shards: shards
       }) do
    shards
    |> Enum.sort_by(fn {axis, _} -> axis end)
    |> Enum.map(fn {axis, shard} -> {shard, axis} end)
    |> cartesian_product()
    |> Enum.map(fn sections ->
      {starts, lengths} =
        sections
        |> Enum.map(fn {shard, _axis} -> {shard.start, shard.length} end)
        |> Enum.unzip()

      data_section_id = Enum.map(sections, fn {shard, _axis} -> shard.id end)

      data = arg_data.()

      data_slice = Nx.slice(data, starts, lengths)

      ShardExecution.ArgumentProvider.start_link([
        data_slice,
        arg_idx,
        data_section_id
      ])
    end)
  end

  defp cartesian_product([{data, meta} | rest]) do
    for x <- data, y <- cartesian_product(rest), do: [{x, meta} | y]
  end

  defp cartesian_product([]), do: [[]]

  defp propagate_shards(vars, fun, :disable) do
    expr = fun.(vars)

    {expr, %{}}
  end

  defp propagate_shards(vars, fun, sharding_config) do
    expr = fun.(vars)

    arity = length(vars)

    sharding_config = sharding_config || List.duplicate(%{}, arity)

    if length(sharding_config) != arity do
      raise "Expected sharding config for function with #{arity} arguments to have the same length"
    end

    tensor_shardings =
      sharding_config
      |> Enum.zip_with(Enum.with_index(vars), fn config, {var, idx} ->
        Shard.from_config(var, config, debug_id: "arg #{idx}")
      end)
      |> Enum.with_index(fn x, idx -> {idx, x} end)
      |> Map.new()

    {container, _cache, %{expr_shards: expr_shards}} =
      ShardPropagation.traverse(expr, tensor_shardings)

    {container, expr_shards}
  end

  @impl true
  def __partitions_options__(_keyword) do
    raise "__partitions_options__ not supported"
  end

  @impl true
  def __to_backend__(_keyword) do
    raise "__to_backend__ not supported"
  end

  def init(opts), do: opts
end
