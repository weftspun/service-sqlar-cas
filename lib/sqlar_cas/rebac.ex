defmodule SqlarCas.ReBAC do
  @moduledoc """
  Zanzibar-style ReBAC over the `relationships` table.

  Tuple: `(object, relation, userset)`; userset is a plain subject or
  `object#relation` (a computed userset). `expand/2` resolves recursively
  with a cycle guard. Bao's write path is the only inserter — the engine
  READS via this module.
  """

  alias SqlarCas.Store

  def grant(object, relation, userset) do
    Store.execute!(
      "INSERT OR IGNORE INTO relationships(object, relation, userset) VALUES (?,?,?)",
      [object, relation, userset]
    )
  end

  def revoke(object, relation, userset) do
    Store.execute!(
      "DELETE FROM relationships WHERE object=? AND relation=? AND userset=?",
      [object, relation, userset]
    )
  end

  def expand(object, relation), do: expand(object, relation, MapSet.new())

  defp expand(object, relation, seen) do
    key = {object, relation}

    if MapSet.member?(seen, key) do
      MapSet.new()
    else
      seen = MapSet.put(seen, key)

      Store.query!(
        "SELECT userset FROM relationships WHERE object=? AND relation=?",
        [object, relation]
      )
      |> Enum.reduce(MapSet.new(), fn [userset], acc ->
        case String.split(userset, "#", parts: 2) do
          [sub_obj, sub_rel] ->
            MapSet.union(acc, expand(sub_obj, sub_rel, seen))

          [_subject] ->
            MapSet.put(acc, userset)
        end
      end)
    end
  end

  def enumerate_readers(object), do: expand(object, "reader") |> Enum.sort()
end
