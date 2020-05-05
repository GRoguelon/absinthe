defmodule Absinthe.Phase.Document.Execution.Resolution3 do
  @moduledoc false

  # Runs resolution functions in a blueprint.
  #
  # Blueprint results are placed under `blueprint.result.execution`. This is
  # because the results form basically a new tree from the original blueprint.

  alias Absinthe.{Blueprint, Type, Phase}
  alias Blueprint.{Result, Execution}

  alias Absinthe.Phase
  use Absinthe.Phase

  @spec run(Blueprint.t(), Keyword.t()) :: Phase.result_t()
  def run(bp_root, options \\ []) do
    case Blueprint.current_operation(bp_root) do
      nil -> {:ok, bp_root}
      op -> resolve_current(bp_root, op, options)
    end
  end

  defp resolve_current(bp_root, operation, options) do
    execution = perform_resolution(bp_root, operation, options)

    blueprint = %{bp_root | execution: execution}

    if Keyword.get(options, :plugin_callbacks, true) do
      bp_root.schema.plugins()
      |> Absinthe.Plugin.pipeline(execution)
      |> case do
        [] ->
          {:ok, blueprint}

        pipeline ->
          {:insert, blueprint, pipeline}
      end
    else
      {:ok, blueprint}
    end
  end

  defp perform_resolution(bp_root, operation, options) do
    start = bp_root.execution.result
    exec = Execution.get(bp_root, operation)

    plugins = bp_root.schema.plugins()
    run_callbacks? = Keyword.get(options, :plugin_callbacks, true)

    {result_stacks, work} =
      case start do
        nil ->
          base_result = %Result.Object{
            root_value: exec.root_value,
            emitter: operation,
            ref: cut_ref()
          }

          stacks = %{
            0 => [{:top, base_result}]
          }

          work = next_work(base_result)

          {stacks, work}
      end

    {result, exec} =
      resolve(
        work,
        Map.fetch!(result_stacks, 0),
        result_stacks,
        bp_root.execution.current_ref,
        exec
      )

    %{exec | result: result}
  end

  defp next_work(%Result.Object{emitter: emitter} = obj) do
    for field <- emitter.selections do
      {:work, obj, field}
    end
  end

  defp next_work(%Result.Leaf{}) do
    []
  end

  @type result :: Result.Object.t() | Result.List.t() | Result.Leaf.t()
  @spec next_work(result) :: [{:work, Result.Object.t() | Result.List.t(), term}]

  def resolve(
        [{:work, parent, field} | remaining_work],
        result_stack,
        result_stacks,
        ref_counter,
        exec
      ) do
    case resolve_field(exec, parent, [], field) do
      %{state: :resolved} = res ->
        exec = update_persisted_fields(exec, res)

        result = build_result(exec, parent, [], res)

        next_work = next_work(result)

        remaining_work = next_work ++ remaining_work
        result_stack = [{parent.ref, result} | result_stack]
        resolve(remaining_work, result_stack, result_stacks, ref_counter, exec)

      %{state: :suspended} = res ->
        raise "suspended fields not yet supported"

      final_res ->
        raise """
        Should have halted or suspended middleware
        Ended with: #{inspect(final_res)}
        """
    end
  end

  def resolve([], current_stack, stacks, ref_counter, exec) do
    {Map.put(stacks, ref_counter, current_stack), exec}
  end

  defp run_callbacks(plugins, callback, acc, true) do
    Enum.reduce(plugins, acc, &apply(&1, callback, [&2]))
  end

  defp run_callbacks(_, _, acc, _), do: acc

  def resolve_field2(exec, parent, path, field) do
    case field.schema_node.middleware do
      [{Absinthe.Middleware.MapGet, key}] ->
        value = Map.get(parent.root_value, key)

        %Absinthe.Resolution{
          value: value,
          definition: field,
          extensions: %{},
          errors: []
        }

      _ ->
        resolve_field(exec, parent, path, field)
    end
  end

  def resolve_field(exec, parent, path, field) do
    exec
    |> build_resolution_struct(field, parent.root_value, parent.emitter.schema_node, path)
    |> reduce_resolution
  end

  defp update_persisted_fields(dest, %{acc: acc, context: context, fields_cache: cache}) do
    %{dest | acc: acc, context: context, fields_cache: cache}
  end

  defp build_resolution_struct(exec, bp_field, source, parent_type, path) do
    common =
      Map.take(exec, [:adapter, :context, :acc, :root_value, :schema, :fragments, :fields_cache])

    %Absinthe.Resolution{
      path: path,
      source: source,
      parent_type: parent_type,
      middleware: bp_field.schema_node.middleware,
      definition: bp_field,
      arguments: bp_field.argument_data
    }
    |> Map.merge(common)
  end

  defp reduce_resolution(%{middleware: []} = res), do: res

  defp reduce_resolution(%{middleware: [middleware | remaining_middleware]} = res) do
    case call_middleware(middleware, %{res | middleware: remaining_middleware}) do
      %{state: :suspended} = res ->
        res

      res ->
        reduce_resolution(res)
    end
  end

  defp call_middleware({{mod, fun}, opts}, res) do
    apply(mod, fun, [res, opts])
  end

  defp call_middleware({mod, opts}, res) do
    apply(mod, :call, [res, opts])
  end

  defp call_middleware(mod, res) when is_atom(mod) do
    apply(mod, :call, [res, []])
  end

  defp call_middleware(fun, res) when is_function(fun, 2) do
    fun.(res, [])
  end

  defp build_result(exec, parent, path, %{errors: errors} = res) do
    %{
      value: value,
      definition: bp_field,
      extensions: extensions
    } = res

    full_type = Type.expand(bp_field.schema_node.type, exec.schema)

    bp_field = put_in(bp_field.schema_node.type, full_type)

    # if there are any errors, the value is always nil
    value =
      case errors do
        [] -> value
        _ -> nil
      end

    errors = maybe_add_non_null_error(errors, value, full_type)

    to_result(value, bp_field, full_type, extensions)
  end

  # defp add_list_values(stack, [], parent_ref) do
  #   stack
  # end

  # defp add_list_values(stack, [value | rest], parent_ref) do
  #   result = to_result(value, bp_field, full_type, extensions)
  # end

  defp maybe_add_non_null_error(errors, nil, %Type.NonNull{}) do
    ["Cannot return null for non-nullable field" | errors]
  end

  defp maybe_add_non_null_error(errors, _, _) do
    errors
  end

  defp propagate_null_trimming({%{values: values} = node, exec}) do
    values = Enum.map(values, &do_propagate_null_trimming/1)
    node = %{node | values: values}
    {do_propagate_null_trimming(node), exec}
  end

  defp propagate_null_trimming({node, exec}) do
    {do_propagate_null_trimming(node), exec}
  end

  defp do_propagate_null_trimming(node) do
    if bad_child = find_bad_child(node) do
      bp_field = node.emitter

      full_type =
        with %{type: type} <- bp_field.schema_node do
          type
        end

      nil
      # |> to_result(bp_field, full_type, node.extensions)
      # |> Map.put(:errors, bad_child.errors)

      # ^ We don't have to worry about clobbering the current node's errors because,
      # if it had any errors, it wouldn't have any children and we wouldn't be
      # here anyway.
    else
      node
    end
  end

  defp find_bad_child(%{fields: fields}) do
    Enum.find(fields, &non_null_violation?/1)
  end

  defp find_bad_child(%{values: values}) do
    Enum.find(values, &non_null_list_violation?/1)
  end

  defp find_bad_child(_) do
    false
  end

  # FIXME: Not super happy with this lookup process
  defp non_null_violation?(%{value: nil, emitter: %{schema_node: %{type: %Type.NonNull{}}}}) do
    true
  end

  defp non_null_violation?(_) do
    false
  end

  # FIXME: Not super happy with this lookup process.
  # Also it would be nice if we could use the same function as above.
  defp non_null_list_violation?(%{
         value: nil,
         emitter: %{schema_node: %{type: %Type.List{of_type: %Type.NonNull{}}}}
       }) do
    true
  end

  defp non_null_list_violation?(_) do
    false
  end

  # defp maybe_add_non_null_error(errors, nil, %)

  defp add_errors(result, errors, fun) do
    Enum.reduce(errors, result, fun)
  end

  defp put_result_error_value(error_value, result, bp_field, source, path) do
    case split_error_value(error_value) do
      {[], _} ->
        raise Absinthe.Resolution.result_error(error_value, bp_field, source)

      {[message: message], extra} ->
        put_error(result, error(bp_field, message, path, Map.new(extra)))
    end
  end

  defp split_error_value(error_value) when is_list(error_value) or is_map(error_value) do
    Keyword.split(Enum.to_list(error_value), [:message])
  end

  defp split_error_value(error_value) when is_binary(error_value) do
    {[message: error_value], []}
  end

  defp split_error_value(error_value) do
    {[message: to_string(error_value)], []}
  end

  defp to_result(nil, blueprint, _, extensions) do
    %Result.Leaf{emitter: blueprint, value: nil, extensions: extensions}
  end

  defp to_result(root_value, blueprint, %Type.NonNull{of_type: inner_type}, extensions) do
    to_result(root_value, blueprint, inner_type, extensions)
  end

  defp to_result(root_value, blueprint, %Type.Object{}, extensions) do
    %Result.Object{
      root_value: root_value,
      emitter: blueprint,
      extensions: extensions,
      ref: cut_ref()
    }
  end

  defp to_result(root_value, blueprint, %Type.Interface{}, extensions) do
    %Result.Object{
      root_value: root_value,
      emitter: blueprint,
      extensions: extensions,
      ref: cut_ref()
    }
  end

  defp to_result(root_value, blueprint, %Type.Union{}, extensions) do
    %Result.Object{
      root_value: root_value,
      emitter: blueprint,
      extensions: extensions,
      ref: cut_ref()
    }
  end

  defp to_result(root_value, blueprint, %Type.List{}, extensions) do
    %Result.List{
      root_value: List.wrap(root_value),
      values: nil,
      emitter: blueprint,
      extensions: extensions,
      ref: cut_ref()
    }
  end

  defp to_result(root_value, blueprint, %Type.Scalar{}, extensions) do
    %Result.Leaf{
      emitter: blueprint,
      value: root_value,
      extensions: extensions
    }
  end

  defp to_result(root_value, blueprint, %Type.Enum{}, extensions) do
    %Result.Leaf{
      emitter: blueprint,
      value: root_value,
      extensions: extensions
    }
  end

  def error(node, message, path, extra) do
    %Phase.Error{
      phase: __MODULE__,
      message: message,
      locations: [node.source_location],
      path: Absinthe.Resolution.path(%{path: path}),
      extra: extra
    }
  end

  def cut_ref() do
    ref = Process.get({__MODULE__, :ref}, 0)
    Process.put({__MODULE__, :ref}, ref + 1)
    ref
  end
end