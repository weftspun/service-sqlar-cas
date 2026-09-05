defmodule SqlarCas.Engine do
  @moduledoc """
  The sqlar-cas engine. Feels like an OpenBao secrets engine — same read
  shapes peers expect — but built in.

  Reads:
    get_sqlar(name)                  -> {version, dek_id, payload_nonce, ...}
    list_wraps_for_dek(dek_id)       -> [{ephemeral_pub, wrapped_key}, ...]
    get_chunk(hash)                  -> ct
    enumerate_readers(object)        -> [subject, ...]
    unwrap_and_verify(name, priv)    -> {:ok, plaintext} | :error

  Writes come from the ingest side (Mix tasks in dev, Bao-mediated in prod).
  """

  alias SqlarCas.{Store, Crypto, ReBAC}

  def get_sqlar(name) do
    case Store.query!("SELECT data, dek_id FROM sqlar WHERE name=?", [name]) do
      [[data, dek_id]] -> {:ok, data, dek_id}
      [] -> :not_found
    end
  end

  def list_wraps_for_dek(dek_id) do
    Store.query!(
      "SELECT ephemeral_pub, wrapped_key FROM sqlar_dek_wraps WHERE dek_id=?",
      [dek_id]
    )
    |> Enum.map(fn [eph, wk] -> {eph, wk} end)
  end

  def get_chunk(hash) do
    case Store.query!("SELECT ct FROM sqlar_chunks WHERE hash=?", [hash]) do
      [[ct]] -> {:ok, ct}
      [] -> :not_found
    end
  end

  def enumerate_readers(object), do: ReBAC.enumerate_readers(object)

  @doc """
  End-to-end: unwrap the file_key for `priv_key` from one of `name`'s
  wraps, verify the header MAC, decrypt caibx, fetch + AEAD-decrypt +
  zstd-decode each chunk, verify pt hashes, reassemble.
  """
  def unwrap_and_verify(name, priv_key) do
    with {:ok, sqlar_data, dek_id} <- get_sqlar(name),
         wraps = list_wraps_for_dek(dek_id),
         {:ok, file_key} <- first_unwrap(wraps, priv_key) do
      decrypt_envelope(file_key, sqlar_data, name)
    end
  end

  defp first_unwrap([], _), do: :error
  defp first_unwrap([{eph, wk} | rest], priv) do
    case Crypto.x25519_unwrap(priv, eph, wk) do
      {:ok, fk} -> {:ok, fk}
      _ -> first_unwrap(rest, priv)
    end
  end

  defp decrypt_envelope(file_key, sqlar_data, name) do
    <<version, dek_id::binary-size(16), payload_nonce::binary-size(16),
      rest::binary>> = sqlar_data
    ct_and_tag_size = byte_size(rest) - 32
    <<ct_and_tag::binary-size(^ct_and_tag_size), header_mac::binary-size(32)>> = rest
    hb = <<version>> <> dek_id <> payload_nonce <> name
    if Crypto.hmac_sha256(Crypto.mac_key(file_key), hb) != header_mac do
      :error
    else
      key = Crypto.payload_key(file_key)
      nonce = binary_part(payload_nonce, 0, 12)
      with {:ok, caibx} <- Crypto.aead_decrypt(key, nonce, ct_and_tag, hb) do
        reassemble(caibx, key)
      end
    end
  end

  defp reassemble(caibx, key) do
    <<n::little-32, rest::binary>> = caibx
    chunks = parse_caibx(rest, n, [])

    Enum.reduce_while(chunks, {:ok, <<>>}, fn {ct_hash, pt_hash, _sz}, {:ok, acc} ->
      with {:ok, ct} <- get_chunk(ct_hash),
           {:ok, compressed} <-
             Crypto.aead_decrypt(key, binary_part(pt_hash, 0, 12), ct, ""),
           iolist when is_list(iolist) <- :zstd.decompress(compressed),
           raw = :erlang.iolist_to_binary(iolist),
           true <- Crypto.sha512_256(raw) == pt_hash do
        {:cont, {:ok, acc <> raw}}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  defp parse_caibx(_bin, 0, acc), do: Enum.reverse(acc)
  defp parse_caibx(<<ct::binary-size(32), pt::binary-size(32), sz::little-64,
                     rest::binary>>, n, acc) do
    parse_caibx(rest, n - 1, [{ct, pt, sz} | acc])
  end
end
