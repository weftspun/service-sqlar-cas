defmodule SqlarCas.Persona do
  @moduledoc """
  Persona reflex executor — a tabletop-RPG-shaped action picker.

  Given a persona and a stimulus (a game event, a scene cue, a die
  roll), returns the first reflex action whose precondition holds
  against the persona's current state. This is HTN's simplest case:
  one-step planning against a small action table, expressible as a
  single SQL query.

  Multi-step decomposition (methods, subtasks, backjumping) is a
  follow-up in Taskweft.SQL. Reflex is enough to drive a scene.

  Where OpenBao plugs in: `load_from_bao/1` (not yet wired) would
  fetch the persona's actions + starting state from Bao's identity
  and relationship tables. Until it exists, seed via `seed/2`.
  """

  alias SqlarCas.Store

  @doc "Insert a persona's reflex actions. Idempotent."
  def seed(persona_id, actions) when is_binary(persona_id) and is_list(actions) do
    for {name, opts} <- actions do
      pre = opts |> Keyword.get(:precondition, %{}) |> Jason.encode!()
      eff = opts |> Keyword.get(:effect, %{}) |> Jason.encode!()
      pri = Keyword.get(opts, :priority, 0)

      Store.execute!(
        "INSERT OR REPLACE INTO persona_actions(persona_id, action_name, precondition_json, effect_json, priority) VALUES (?,?,?,?,?)",
        [persona_id, name, pre, eff, pri]
      )
    end

    :ok
  end

  @doc "Set one state binding for a persona."
  def set_state(persona_id, pointer, value) do
    Store.execute!(
      "INSERT OR REPLACE INTO persona_state(persona_id, pointer, value) VALUES (?,?,?)",
      [persona_id, pointer, to_string(value)]
    )
  end

  @doc "Read the full state of a persona as a map."
  def state(persona_id) do
    Store.query!(
      "SELECT pointer, value FROM persona_state WHERE persona_id=?",
      [persona_id]
    )
    |> Map.new(fn [p, v] -> {p, v} end)
  end

  @doc """
  Pick the first reflex action whose precondition holds against the
  persona's state, ordered by descending priority.

  Preconditions are a map of `{pointer => expected_value}`; a `nil`
  expected_value means "pointer must NOT be set". Stimulus is folded
  into the precondition check as `pointer "_stimulus"`.

  Returns `{:ok, %{action: name, effect: %{...}}}` or `:no_match`.
  """
  def reflex(persona_id, stimulus) do
    state = state(persona_id) |> Map.put("_stimulus", stimulus)

    Store.query!(
      "SELECT action_name, precondition_json, effect_json FROM persona_actions WHERE persona_id=? ORDER BY priority DESC, action_name",
      [persona_id]
    )
    |> Enum.find_value(:no_match, fn [name, pre_json, eff_json] ->
      pre = Jason.decode!(pre_json)

      if pre_matches?(pre, state) do
        eff = Jason.decode!(eff_json)
        # Apply effect to state.
        for {ptr, val} <- eff, do: set_state(persona_id, ptr, val)
        {:ok, %{action: name, effect: eff}}
      end
    end)
  end

  defp pre_matches?(pre, state) do
    Enum.all?(pre, fn {ptr, expected} ->
      actual = Map.get(state, ptr)
      to_string(expected) == actual
    end)
  end
end
