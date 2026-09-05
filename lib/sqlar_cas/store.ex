defmodule SqlarCas.Store do
  @moduledoc """
  SQLite handle wrapping fabric-store's FDB VFS in prod, or a local file /
  :memory: in dev. Owns the sqlar / sqlar_dek_wraps / sqlar_chunks /
  relationships tables. Read-only from the HTTP layer; writes come from
  Mix tasks and the write-side ingest.
  """
  use GenServer
  alias Exqlite.Sqlite3

  @schema """
  CREATE TABLE IF NOT EXISTS sqlar(
    name TEXT PRIMARY KEY, mode INTEGER, mtime INTEGER,
    sz INTEGER, data BLOB, dek_id BLOB);
  CREATE TABLE IF NOT EXISTS sqlar_dek_wraps(
    dek_id BLOB, ephemeral_pub BLOB, wrapped_key BLOB,
    PRIMARY KEY(dek_id, ephemeral_pub));
  CREATE TABLE IF NOT EXISTS sqlar_chunks(hash BLOB PRIMARY KEY, ct BLOB);
  CREATE TABLE IF NOT EXISTS relationships(
    object TEXT, relation TEXT, userset TEXT,
    PRIMARY KEY(object, relation, userset));
  """

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    db = Keyword.fetch!(opts, :db)
    File.mkdir_p!(Path.dirname(db))
    {:ok, conn} = Sqlite3.open(db)
    :ok = Sqlite3.execute(conn, @schema)
    {:ok, %{conn: conn}}
  end

  def query!(sql, params \\ []), do: GenServer.call(__MODULE__, {:query, sql, params})

  def execute!(sql, params \\ []), do: GenServer.call(__MODULE__, {:execute, sql, params})

  @impl true
  def handle_call({:query, sql, params}, _from, %{conn: conn} = state) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)
    :ok = Sqlite3.bind(stmt, params)
    rows = stream(conn, stmt, [])
    Sqlite3.release(conn, stmt)
    {:reply, rows, state}
  end

  def handle_call({:execute, sql, params}, _from, %{conn: conn} = state) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)
    :ok = Sqlite3.bind(stmt, params)
    :done = Sqlite3.step(conn, stmt)
    Sqlite3.release(conn, stmt)
    {:reply, :ok, state}
  end

  defp stream(conn, stmt, acc) do
    case Sqlite3.step(conn, stmt) do
      {:row, row} -> stream(conn, stmt, [row | acc])
      :done -> Enum.reverse(acc)
    end
  end
end
