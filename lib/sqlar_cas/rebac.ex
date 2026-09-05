defmodule SqlarCas.ReBAC do
  @moduledoc """
  Zanzibar-style ReBAC over the `relationships` table.

  A tuple is `(object, relation, userset, caveat?)`. Userset is a
  plain subject or `object#relation` (a computed userset). Caveat
  is a JSON conditional predicate evaluated at check time
  (see `SqlarCas.Caveat`); TTL is one caveat kind among an
  extensible set. Unconditional tuples carry a NULL caveat.

  `expand/2` resolves recursively with a cycle guard and filters
  out tuples whose caveat is unsatisfied for the current context.
  """

  alias SqlarCas.{Store, Caveat}

  @doc """
  Grant a tuple, optionally with a caveat.

    grant("world", "reader", "alice")
    grant("world", "reader", "alice", Caveat.expires_at(1_800_000_000))
  """
  def grant(object, relation, userset, caveat \\ nil) do
    Store.execute!(
      "INSERT OR REPLACE INTO relationships(object, relation, userset, caveat) VALUES (?,?,?,?)",
      [object, relation, userset, Caveat.encode(caveat)]
    )
  end

  def revoke(object, relation, userset) do
    Store.execute!(
      "DELETE FROM relationships WHERE object=? AND relation=? AND userset=?",
      [object, relation, userset]
    )
  end

  @doc """
  Delete every tuple whose caveat is unsatisfied at `now`. Idempotent.
  Used for background GC — the check-time evaluation in `expand`
  already excludes them from grants, this just reclaims rows.
  """
  def gc_unsatisfied(now \\ System.system_time(:second)) do
    ctx = %{now: now}

    rows =
      Store.query!(
        "SELECT object, relation, userset, caveat FROM relationships WHERE caveat IS NOT NULL"
      )

    for [obj, rel, us, cav_json] <- rows,
        not Caveat.satisfied?(Caveat.decode(cav_json), ctx) do
      Store.execute!(
        "DELETE FROM relationships WHERE object=? AND relation=? AND userset=?",
        [obj, rel, us]
      )
    end
  end

  def expand(object, relation),
    do: expand(object, relation, MapSet.new(), %{now: System.system_time(:second)})

  defp expand(object, relation, seen, ctx) do
    key = {object, relation}

    if MapSet.member?(seen, key) do
      MapSet.new()
    else
      seen = MapSet.put(seen, key)

      Store.query!(
        "SELECT userset, caveat FROM relationships WHERE object=? AND relation=?",
        [object, relation]
      )
      |> Enum.reduce(MapSet.new(), fn [userset, cav_json], acc ->
        if Caveat.satisfied?(Caveat.decode(cav_json), ctx) do
          case String.split(userset, "#", parts: 2) do
            [sub_obj, sub_rel] ->
              MapSet.union(acc, expand(sub_obj, sub_rel, seen, ctx))

            [_subject] ->
              MapSet.put(acc, userset)
          end
        else
          acc
        end
      end)
    end
  end

  def enumerate_readers(object), do: expand(object, "reader") |> Enum.sort()
end
