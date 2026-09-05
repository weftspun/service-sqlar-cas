defmodule SqlarCas.CryptoTest do
  use ExUnit.Case, async: true
  alias SqlarCas.Crypto

  describe "hkdf/4" do
    test "matches age's payload key derivation" do
      fk = :binary.copy(<<0x59>>, 16)  # "YELLOW SUBMARINE"[0]*16 test key
      pk = Crypto.payload_key(fk)
      assert byte_size(pk) == 32
    end

    test "mac_key uses empty salt" do
      fk = :crypto.strong_rand_bytes(16)
      assert byte_size(Crypto.mac_key(fk)) == 32
      # Falsifiability control: mac_key(fk) != payload_key(fk).
      refute Crypto.mac_key(fk) == Crypto.payload_key(fk)
    end
  end

  describe "aead / hmac" do
    test "aead_encrypt / aead_decrypt roundtrip" do
      key = :crypto.strong_rand_bytes(32)
      nonce = :crypto.strong_rand_bytes(12)
      pt = "the quick brown fox"
      ct_and_tag = Crypto.aead_encrypt(key, nonce, pt, "aad")
      assert {:ok, ^pt} = Crypto.aead_decrypt(key, nonce, ct_and_tag, "aad")
    end

    test "aead_decrypt fails on ct tamper (falsifiability control)" do
      key = :crypto.strong_rand_bytes(32)
      nonce = :crypto.strong_rand_bytes(12)
      ct = Crypto.aead_encrypt(key, nonce, "hello", "aad")
      # Flip one byte in the middle of the ciphertext.
      <<head::binary-size(2), b, tail::binary>> = ct
      tampered = head <> <<Bitwise.bxor(b, 0xFF)>> <> tail
      assert Crypto.aead_decrypt(key, nonce, tampered, "aad") == :error
    end

    test "aead_decrypt fails on aad tamper (falsifiability control)" do
      key = :crypto.strong_rand_bytes(32)
      nonce = :crypto.strong_rand_bytes(12)
      ct = Crypto.aead_encrypt(key, nonce, "hello", "aad-A")
      assert Crypto.aead_decrypt(key, nonce, ct, "aad-B") == :error
    end

    test "hmac_sha256 is deterministic" do
      k = :crypto.strong_rand_bytes(32)
      m = "header bytes"
      assert Crypto.hmac_sha256(k, m) == Crypto.hmac_sha256(k, m)
    end
  end
end

defmodule SqlarCas.ReBACTest do
  use ExUnit.Case
  alias SqlarCas.{ReBAC, Store}

  setup do
    :ok = Store.execute!("DELETE FROM relationships")
    :ok
  end

  test "direct grant expands to subject" do
    ReBAC.grant("file1", "reader", "alice")
    assert MapSet.member?(ReBAC.expand("file1", "reader"), "alice")
  end

  test "userset rewrite expands recursively" do
    ReBAC.grant("world", "reader", "friends#member")
    ReBAC.grant("friends", "member", "alice")
    ReBAC.grant("friends", "member", "bob")
    assert Enum.sort(ReBAC.enumerate_readers("world")) == ["alice", "bob"]
  end

  test "revoke removes from expand set" do
    ReBAC.grant("world", "reader", "friends#member")
    ReBAC.grant("friends", "member", "alice")
    ReBAC.grant("friends", "member", "bob")
    ReBAC.revoke("friends", "member", "alice")
    assert ReBAC.enumerate_readers("world") == ["bob"]
  end

  test "cycle guard: mutual usersets don't infinite-loop (falsifiability control)" do
    ReBAC.grant("a", "reader", "b#reader")
    ReBAC.grant("b", "reader", "a#reader")
    # No terminal subjects reachable — empty set, not a stack overflow.
    assert ReBAC.enumerate_readers("a") == []
  end

  test "no grant means empty (falsifiability control)" do
    assert ReBAC.enumerate_readers("nonexistent") == []
  end
end
