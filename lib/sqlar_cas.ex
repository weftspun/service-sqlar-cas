defmodule SqlarCas do
  @moduledoc false
end

defmodule SqlarCas.Application do
  use Application

  @impl true
  def start(_type, _args) do
    db = System.get_env("SQLAR_CAS_DB") ||
           if Mix.env() == :test, do: ":memory:", else: "priv/sqlar_cas.sqlite"

    children =
      [{SqlarCas.Store, db: db}] ++
        if Mix.env() == :test do
          []  # tests exercise the engine directly; no HTTP listener
        else
          port = String.to_integer(System.get_env("SQLAR_CAS_PORT") || "8200")
          [{Bandit, plug: SqlarCas.Router, port: port}]
        end

    Supervisor.start_link(children, strategy: :one_for_one, name: SqlarCas.Supervisor)
  end
end
