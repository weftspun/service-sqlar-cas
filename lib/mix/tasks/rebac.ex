defmodule Mix.Tasks.Rebac do
  @moduledoc """
  CRUD over sqlar-cas ReBAC tuples from a terminal UI.

    mix rebac                            interactive menu
    mix rebac list                       every tuple in the store
    mix rebac expand <object> [relation] expand userset (default: reader)
    mix rebac grant <object> <relation> <userset> [--ttl-secs N]
    mix rebac revoke <object> <relation> <userset>
    mix rebac gc                         delete tuples whose caveat is unsatisfied

  `userset` is a plain subject or `object#relation` (Zanzibar userset rewrite).
  Cycle-safe expand; guards against mutual grants deadlocking the walk.

  `--ttl-secs N` attaches an `expires_at` caveat (SqlarCas.Caveat).
  TTL is one caveat kind; the slot is first-class and extensible.
  """
  use Mix.Task
  alias SqlarCas.{Store, ReBAC, Caveat}

  @shortdoc "ReBAC CRUD TUI over the sqlar-cas store"

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:sqlar_cas)

    case args do
      [] -> menu()
      ["list"] -> cmd_list()
      ["gc"] -> cmd_gc()
      ["expand", object] -> cmd_expand(object, "reader")
      ["expand", object, relation] -> cmd_expand(object, relation)
      ["grant", object, relation, userset | rest] ->
        cmd_grant(object, relation, userset, parse_caveat(rest))
      ["revoke", object, relation, userset] -> cmd_revoke(object, relation, userset)
      _ -> IO.puts(@moduledoc)
    end
  end

  defp parse_caveat(["--ttl-secs", n]) do
    Caveat.expires_at(System.system_time(:second) + String.to_integer(n))
  end
  defp parse_caveat(_), do: nil

  defp menu do
    banner()
    loop()
  end

  defp banner do
    IO.puts("")
    IO.puts(IO.ANSI.bright() <> "sqlar-cas ReBAC" <> IO.ANSI.reset())
    IO.puts(String.duplicate("─", 40))
  end

  defp loop do
    IO.puts("")
    IO.puts("  [1] list all tuples")
    IO.puts("  [2] expand readers of an object")
    IO.puts("  [3] grant  object#relation@userset  (optional TTL secs)")
    IO.puts("  [4] revoke object#relation@userset")
    IO.puts("  [5] gc unsatisfied caveats")
    IO.puts("  [q] quit")
    case IO.gets("> ") |> String.trim() do
      "1" -> cmd_list(); loop()
      "2" -> cmd_expand(prompt("object: "), prompt("relation [reader]: ", "reader")); loop()
      "3" ->
        obj = prompt("object: ")
        rel = prompt("relation: ")
        us  = prompt("userset: ")
        cav = case prompt("ttl seconds (blank = unconditional): ", "") do
          "" -> nil
          n  -> Caveat.expires_at(System.system_time(:second) + String.to_integer(n))
        end
        cmd_grant(obj, rel, us, cav)
        loop()
      "4" ->
        cmd_revoke(prompt("object: "), prompt("relation: "), prompt("userset: "))
        loop()
      "5" -> cmd_gc(); loop()
      "q" -> :ok
      _ -> IO.puts("(unknown)"); loop()
    end
  end

  defp prompt(label, default \\ nil) do
    line = IO.gets(label) |> String.trim()
    if line == "" and default, do: default, else: line
  end

  defp cmd_list do
    rows = Store.query!(
      "SELECT object, relation, userset, caveat FROM relationships ORDER BY object, relation, userset"
    )
    IO.puts("")
    IO.puts(pad("OBJECT", 20) <> pad("RELATION", 14) <> pad("USERSET", 20) <> "CAVEAT")
    IO.puts(String.duplicate("─", 74))
    for [o, r, u, cav_json] <- rows do
      IO.puts(pad(o, 20) <> pad(r, 14) <> pad(u, 20) <> Caveat.summary(Caveat.decode(cav_json)))
    end
    IO.puts("  (#{length(rows)} tuple#{if length(rows) == 1, do: "", else: "s"})")
  end

  defp cmd_expand(object, relation) do
    subjects = ReBAC.expand(object, relation) |> Enum.sort()
    IO.puts("")
    IO.puts("#{IO.ANSI.bright()}#{object}##{relation}#{IO.ANSI.reset()} expands to:")
    for s <- subjects, do: IO.puts("  #{s}")
    IO.puts("  (#{length(subjects)} subject#{if length(subjects) == 1, do: "", else: "s"})")
  end

  defp cmd_grant(object, relation, userset, caveat \\ nil) do
    ReBAC.grant(object, relation, userset, caveat)
    label = if caveat, do: " " <> Caveat.summary(caveat), else: ""
    IO.puts("  #{IO.ANSI.green()}granted#{IO.ANSI.reset()} #{object}##{relation}@#{userset}#{label}")
  end

  defp cmd_revoke(object, relation, userset) do
    ReBAC.revoke(object, relation, userset)
    IO.puts("  #{IO.ANSI.yellow()}revoked#{IO.ANSI.reset()} #{object}##{relation}@#{userset}")
  end

  defp cmd_gc do
    ReBAC.gc_unsatisfied()
    IO.puts("  #{IO.ANSI.yellow()}gc'd#{IO.ANSI.reset()} unsatisfied-caveat tuples")
  end

  defp pad(s, n), do: String.pad_trailing(to_string(s), n)
end
