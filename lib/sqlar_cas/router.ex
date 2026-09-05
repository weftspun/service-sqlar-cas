defmodule SqlarCas.Router do
  @moduledoc """
  Own routes. `/v1/` is the industry versioning convention (Kubernetes,
  GitHub, Stripe all use it), not Bao mimicry. We don't ship `/v1/sys/mounts`
  or any of Bao's other self-description surface — this service is one
  engine, addressed at its own hostname.
  """
  use Plug.Router

  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :dispatch

  get "/v1/sys/health" do
    send_resp(conn, 200, Jason.encode!(%{status: "ok", engine: "sqlar-cas"}))
  end

  get "/v1/sqlar-cas/readers/:object" do
    subjects = SqlarCas.Engine.enumerate_readers(object)
    send_resp(conn, 200, Jason.encode!(%{object: object, readers: subjects}))
  end

  get "/v1/sqlar-cas/sqlar/:name" do
    case SqlarCas.Engine.get_sqlar(name) do
      {:ok, data, dek_id} ->
        send_resp(conn, 200, Jason.encode!(%{
          name: name,
          size: byte_size(data),
          dek_id_hex: Base.encode16(dek_id, case: :lower)
        }))
      :not_found -> send_resp(conn, 404, Jason.encode!(%{errors: ["not found"]}))
    end
  end

  get "/v1/sqlar-cas/chunk/:hash_hex" do
    with {:ok, hash} <- Base.decode16(hash_hex, case: :lower),
         {:ok, ct} <- SqlarCas.Engine.get_chunk(hash) do
      conn
      |> put_resp_header("content-type", "application/octet-stream")
      |> send_resp(200, ct)
    else
      _ -> send_resp(conn, 404, Jason.encode!(%{errors: ["not found"]}))
    end
  end

  match _, do: send_resp(conn, 404, Jason.encode!(%{errors: ["no route"]}))
end
