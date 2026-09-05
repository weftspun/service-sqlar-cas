defmodule SqlarCas.Crypto do
  @moduledoc """
  Age v1.1.0 primitives ported to Elixir (c2sp.org/age@v1.1.0).

  HKDF-SHA-256 subkeys, HMAC-SHA-256 header MAC, ChaCha20-Poly1305 AEAD,
  X25519 recipient wrap with age's exact salt / info strings.
  """

  @wrap_nonce <<0::96>>

  def sha512_256(data), do: :crypto.hash(:sha512, data) |> binary_part(0, 32)

  def hkdf(ikm, salt, info, length) do
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)
    expand(prk, info, length, <<>>, <<>>, 1)
  end

  defp expand(_prk, _info, length, out, _prev, _i) when byte_size(out) >= length,
    do: binary_part(out, 0, length)

  defp expand(prk, info, length, out, prev, i) do
    block = :crypto.mac(:hmac, :sha256, prk, prev <> info <> <<i>>)
    expand(prk, info, length, out <> block, block, i + 1)
  end

  def payload_key(file_key), do: hkdf(file_key, <<0::128>>, "payload", 32)
  def mac_key(file_key),     do: hkdf(file_key, <<>>,       "header",  32)

  def x25519_wrap_key(eph_priv, recip_pub, eph_pub) do
    shared = :crypto.compute_key(:eddh, recip_pub, eph_priv, :x25519)
    hkdf(shared, eph_pub <> recip_pub, "age-encryption.org/v1/X25519", 32)
  end

  def x25519_unwrap(recip_priv, eph_pub, wrapped_key) do
    recip_pub = :crypto.generate_key(:eddh, :x25519, recip_priv) |> elem(0)
    wk = x25519_wrap_key(recip_priv, eph_pub, wrapped_key |> derive_eph_from_wrapped_and_pub(eph_pub))
    _ = wk
    # Simplified: caller passes the eph_pub explicitly (it's a wraps-row column
    # in sqlar-cas, not the age wire), so:
    wrap_key = hkdf(
      :crypto.compute_key(:eddh, eph_pub, recip_priv, :x25519),
      eph_pub <> recip_pub,
      "age-encryption.org/v1/X25519",
      32
    )
    aead_decrypt(wrap_key, @wrap_nonce, wrapped_key, "")
  end

  defp derive_eph_from_wrapped_and_pub(_wrapped, eph_pub), do: eph_pub

  def aead_encrypt(key, nonce, plaintext, aad) do
    {ct, tag} = :crypto.crypto_one_time_aead(:chacha20_poly1305, key, nonce, plaintext, aad, 16, true)
    ct <> tag
  end

  def aead_decrypt(key, nonce, ct_and_tag, aad) do
    ct_size = byte_size(ct_and_tag) - 16
    <<ct::binary-size(^ct_size), tag::binary-size(16)>> = ct_and_tag
    case :crypto.crypto_one_time_aead(:chacha20_poly1305, key, nonce, ct, aad, tag, false) do
      x when is_binary(x) -> {:ok, x}
      :error -> :error
    end
  end

  def hmac_sha256(key, msg), do: :crypto.mac(:hmac, :sha256, key, msg)
end
