defmodule Mix.Tasks.Persona.Play do
  @moduledoc """
  Play a one-scene tabletop encounter driven by persona reflexes.

    mix persona.play                    seeds the demo scene + interactive loop

  Two personas — a traveler and a guide — respond to the stimuli you
  type. Each stimulus triggers each persona's reflex against its
  current state; the executor picks the highest-priority action whose
  precondition matches, applies its effect, and prints what happens.

  Seed is generic isekai: a traveler arriving at a crossroads, a guide
  who offers directions if asked and warns if the hour is late. Swap
  in your own persona sheets by extending the seed block below.
  """
  use Mix.Task
  alias SqlarCas.Persona

  @shortdoc "Play a persona-driven scene (isekai crossroads demo)"

  @impl Mix.Task
  def run(_args) do
    Application.ensure_all_started(:sqlar_cas)
    seed_scene()
    banner()
    loop()
  end

  defp seed_scene do
    Persona.seed("traveler", [
      {"look_around", precondition: %{"_stimulus" => "arrive"}, priority: 10,
       effect: %{"location" => "crossroads"}},
      {"greet_guide", precondition: %{"_stimulus" => "guide_present", "location" => "crossroads"},
       priority: 5, effect: %{"talking_to" => "guide"}},
      {"ask_directions", precondition: %{"_stimulus" => "wait", "talking_to" => "guide"},
       priority: 5, effect: %{"knows_route" => "true"}},
      {"leave", precondition: %{"_stimulus" => "depart", "knows_route" => "true"},
       priority: 10, effect: %{"location" => "on_the_road"}}
    ])

    Persona.seed("guide", [
      {"offer_help", precondition: %{"_stimulus" => "traveler_arrived", "hour" => "day"},
       priority: 5, effect: %{"posture" => "helpful"}},
      {"warn_of_night", precondition: %{"_stimulus" => "traveler_arrived", "hour" => "night"},
       priority: 10, effect: %{"posture" => "cautious"}},
      {"give_directions", precondition: %{"_stimulus" => "asked", "posture" => "helpful"},
       priority: 10, effect: %{"gave_route" => "true"}}
    ])

    Persona.set_state("traveler", "hour", "day")
    Persona.set_state("guide", "hour", "day")
  end

  defp banner do
    IO.puts("")
    IO.puts(IO.ANSI.bright() <> "isekai crossroads (persona reflex demo)" <> IO.ANSI.reset())
    IO.puts(String.duplicate("─", 60))
    IO.puts("stimuli you can send: arrive, guide_present, traveler_arrived,")
    IO.puts("                      asked, wait, depart, set-night")
    IO.puts("commands:  who, state <persona>, q")
    IO.puts("")
  end

  defp loop do
    line = IO.gets("> ") |> String.trim()

    case line do
      "q" -> :ok
      "who" -> IO.puts("  personas: traveler, guide"); loop()
      "state " <> p -> print_state(p); loop()
      "set-night" ->
        Persona.set_state("traveler", "hour", "night")
        Persona.set_state("guide", "hour", "night")
        IO.puts("  " <> IO.ANSI.faint() <> "(hour is now night)" <> IO.ANSI.reset())
        loop()
      "" -> loop()
      stimulus ->
        for persona <- ["traveler", "guide"] do
          case Persona.reflex(persona, stimulus) do
            {:ok, %{action: a, effect: e}} ->
              IO.puts("  #{colored(persona)} → #{IO.ANSI.bright()}#{a}#{IO.ANSI.reset()}  " <>
                        IO.ANSI.faint() <> inspect(e) <> IO.ANSI.reset())
            :no_match -> :skip
          end
        end
        loop()
    end
  end

  defp print_state(persona) do
    st = Persona.state(persona)
    IO.puts("  #{colored(persona)} state:")
    for {k, v} <- st, do: IO.puts("    #{k} = #{v}")
  end

  defp colored("traveler"), do: IO.ANSI.cyan() <> "traveler" <> IO.ANSI.reset()
  defp colored("guide"),    do: IO.ANSI.magenta() <> "guide" <> IO.ANSI.reset()
  defp colored(p),          do: p
end
