defmodule Baileys.Crypto.XEdDSA do
  @moduledoc """
  XEd25519 signatures compatible with Signal's Curve25519 signing scheme.

  Ported from Amarula's MIT-licensed XEdDSA implementation. The scalar
  multiplication is not constant-time and must not be exposed as a general
  purpose signing service.
  """

  import Bitwise

  @p (1 <<< 255) - 19
  @l (1 <<< 252) + 27_742_317_777_372_353_535_851_937_790_883_648_493
  @d 37_095_705_934_669_439_343_138_083_508_754_565_189_542_113_879_843_219_016_388_785_533_085_940_283_555
  @bx 15_112_221_349_535_400_772_501_151_409_588_531_511_454_012_693_041_857_206_046_113_283_949_847_762_202
  @by 46_316_835_694_926_478_169_428_394_003_475_163_141_307_993_866_256_225_615_783_033_603_165_251_855_960
  @sign_prefix <<0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
                 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
                 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>

  @spec sign(binary(), binary()) :: binary()
  def sign(message, <<private::binary-size(32)>>) do
    scalar_integer = clamp(:binary.decode_unsigned(private, :little))
    scalar = scalar_integer |> :binary.encode_unsigned(:little) |> pad_little_endian(32)
    encoded_public = encode_point(scalar_mult_base(scalar_integer))
    sign_bit = :binary.at(encoded_public, 31) &&& 0x80

    nonce =
      sha512_mod_l(@sign_prefix <> scalar <> message <> :crypto.strong_rand_bytes(64))

    encoded_r = encode_point(scalar_mult_base(nonce))
    hram = sha512_mod_l(encoded_r <> encoded_public <> message)
    encoded_s = Integer.mod(hram * scalar_integer + nonce, @l)
    encoded_s = encoded_s |> :binary.encode_unsigned(:little) |> pad_little_endian(32)
    <<head::binary-size(63), last>> = encoded_r <> encoded_s
    <<head::binary, (last &&& 0x7F) ||| sign_bit>>
  end

  @spec verify(binary(), binary(), binary()) :: boolean()
  def verify(message, <<signature::binary-size(64)>>, <<montgomery_public::binary-size(32)>>) do
    <<head::binary-size(63), last>> = signature
    sign_bit = last &&& 0x80
    ed25519_signature = <<head::binary, last &&& 0x7F>>

    case montgomery_to_edwards(montgomery_public, sign_bit) do
      {:ok, edwards_public} ->
        :crypto.verify(:eddsa, :none, message, ed25519_signature, [edwards_public, :ed25519])

      :error ->
        false
    end
  end

  def verify(_message, _signature, _public_key), do: false

  @spec montgomery_to_edwards(binary(), 0 | 0x80) :: {:ok, binary()} | :error
  def montgomery_to_edwards(<<montgomery_public::binary-size(32)>>, sign_bit) do
    u = Integer.mod(:binary.decode_unsigned(montgomery_public, :little) &&& (1 <<< 255) - 1, @p)

    if u == @p - 1 do
      :error
    else
      y = Integer.mod((u - 1) * inverse(u + 1), @p)

      <<head::binary-size(31), last>> =
        y |> :binary.encode_unsigned(:little) |> pad_little_endian(32)

      {:ok, <<head::binary, (last &&& 0x7F) ||| sign_bit>>}
    end
  end

  defp point_add({x1, y1, z1, t1}, {x2, y2, z2, t2}) do
    a = Integer.mod((y1 - x1) * (y2 - x2), @p)
    b = Integer.mod((y1 + x1) * (y2 + x2), @p)
    c = Integer.mod(2 * t1 * t2 * @d, @p)
    d = Integer.mod(2 * z1 * z2, @p)
    e = b - a
    f = d - c
    g = d + c
    h = b + a

    {Integer.mod(e * f, @p), Integer.mod(g * h, @p), Integer.mod(f * g, @p),
     Integer.mod(e * h, @p)}
  end

  defp scalar_mult_base(scalar) do
    scalar_mult(scalar, {@bx, @by, 1, Integer.mod(@bx * @by, @p)})
  end

  defp scalar_mult(scalar, point), do: scalar_mult(scalar, point, {0, 1, 1, 0})
  defp scalar_mult(0, _point, accumulator), do: accumulator

  defp scalar_mult(scalar, point, accumulator) do
    accumulator = if (scalar &&& 1) == 1, do: point_add(accumulator, point), else: accumulator
    scalar_mult(scalar >>> 1, point_add(point, point), accumulator)
  end

  defp encode_point({x, y, z, _t}) do
    inverse_z = inverse(z)
    affine_x = Integer.mod(x * inverse_z, @p)
    affine_y = Integer.mod(y * inverse_z, @p)

    <<head::binary-size(31), last>> =
      affine_y |> :binary.encode_unsigned(:little) |> pad_little_endian(32)

    <<head::binary, last ||| (affine_x &&& 1) <<< 7>>
  end

  defp clamp(value), do: (value &&& (1 <<< 254) - 8) ||| 1 <<< 254
  defp inverse(value), do: pow_mod(Integer.mod(value, @p), @p - 2, @p)
  defp pow_mod(_base, 0, _modulus), do: 1

  defp pow_mod(base, exponent, modulus) do
    half = pow_mod(base, exponent >>> 1, modulus)
    squared = Integer.mod(half * half, modulus)
    if (exponent &&& 1) == 1, do: Integer.mod(squared * base, modulus), else: squared
  end

  defp sha512_mod_l(data) do
    :crypto.hash(:sha512, data) |> :binary.decode_unsigned(:little) |> Integer.mod(@l)
  end

  defp pad_little_endian(binary, size) when byte_size(binary) >= size do
    binary_part(binary, 0, size)
  end

  defp pad_little_endian(binary, size) do
    binary <> :binary.copy(<<0>>, size - byte_size(binary))
  end
end
