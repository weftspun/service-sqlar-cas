defmodule SqlarCas.Caveat do
  @moduledoc """
  Conditional predicate on a ReBAC tuple.

  A caveat is a JSON expression evaluated against a context at check
  time. Today the only kind is `expires_at` (TTL). The JSON shape lives
  in the model rather than as a bare column so TTL is a first-class
  part of the tuple, not a wart on the schema.
  """

  @type context :: %{now: pos_integer()}
  @type t :: nil | map()

  @doc "TTL caveat helper: expires at unix-seconds `at`."
  def expires_at(at) when is_integer(at) and at > 0,
    do: %{"type" => "expires_at", "at" => at}

  @doc "Encode a caveat map to the JSON stored in `relationships.caveat`."
  def encode(nil), do: nil
  def encode(caveat) when is_map(caveat), do: Jason.encode!(caveat)

  @doc "Decode a stored caveat back to a map. `nil` stays `nil`."
  def decode(nil), do: nil
  def decode(json) when is_binary(json), do: Jason.decode!(json)

  @doc """
  True if the caveat is satisfied under `context`. Unconditional
  tuples (`nil` caveat) are always satisfied.
  """
  @spec satisfied?(t(), context()) :: boolean()
  def satisfied?(nil, _ctx), do: true

  def satisfied?(%{"type" => "expires_at", "at" => at}, %{now: now}) when is_integer(at),
    do: now < at

  def satisfied?(_unknown, _ctx), do: false

  @doc "Human-readable summary for the TUI and logs."
  def summary(nil), do: ""
  def summary(%{"type" => "expires_at", "at" => at}),
    do: "(expires " <> to_string(DateTime.from_unix!(at)) <> ")"
  def summary(other), do: "(caveat: " <> inspect(other) <> ")"
end
