defmodule BaileysExo.Protocol.Handshake do
  @moduledoc false

  alias BaileysExo.Auth.Credentials
  alias BaileysExo.Crypto
  alias BaileysExo.Crypto.XEdDSA
  alias BaileysExo.Noise
  alias BaileysExo.Protocol.Payload
  alias BaileysExo.Proto.{CertChain, HandshakeMessage}

  @certificate_public_key Base.decode16!(
                            "142375574D0A587166AAE71EBE516437C4A28B73E3695C6CE1F7F9545DA8EE6B"
                          )

  def client_hello(ephemeral_public) do
    %HandshakeMessage{
      clientHello: %HandshakeMessage.ClientHello{ephemeral: ephemeral_public}
    }
    |> Protobuf.encode()
  end

  def process_server_hello(
        encoded,
        %Noise{} = noise,
        ephemeral_key,
        %Credentials{} = credentials,
        options \\ []
      ) do
    with %HandshakeMessage{serverHello: server_hello} <- HandshakeMessage.decode(encoded),
         true <- not is_nil(server_hello) || {:error, :missing_server_hello},
         noise = Noise.authenticate(noise, server_hello.ephemeral),
         shared = Crypto.x25519(ephemeral_key.private, server_hello.ephemeral),
         noise = Noise.mix_key(noise, shared),
         {:ok, server_static, noise} <- Noise.decrypt(noise, server_hello.static),
         noise = Noise.mix_key(noise, Crypto.x25519(ephemeral_key.private, server_static)),
         {:ok, certificate, noise} <- Noise.decrypt(noise, server_hello.payload),
         :ok <- verify_certificate(certificate),
         {encrypted_static, noise} <- Noise.encrypt(noise, credentials.noise_key.public),
         noise =
           Noise.mix_key(
             noise,
             Crypto.x25519(credentials.noise_key.private, server_hello.ephemeral)
           ),
         payload = client_payload(credentials, options),
         {encrypted_payload, noise} <- Noise.encrypt(noise, Protobuf.encode(payload)) do
      client_finish =
        %HandshakeMessage{
          clientFinish: %HandshakeMessage.ClientFinish{
            static: encrypted_static,
            payload: encrypted_payload
          }
        }
        |> Protobuf.encode()

      {client_finish_frame, noise} = Noise.encode_frame(noise, client_finish)
      {:ok, client_finish_frame, Noise.finish(noise)}
    else
      false -> {:error, :invalid_server_hello}
      {:error, _reason} = error -> error
      error -> {:error, error}
    end
  rescue
    error -> {:error, error}
  end

  def verify_certificate(encoded) do
    certificate = CertChain.decode(encoded)
    intermediate = certificate.intermediate
    leaf = certificate.leaf

    with true <- valid_certificate?(intermediate) and valid_certificate?(leaf),
         details <- CertChain.NoiseCertificate.Details.decode(intermediate.details),
         true <- details.issuerSerial == 0,
         true <- XEdDSA.verify(leaf.details, leaf.signature, details.key),
         true <-
           XEdDSA.verify(
             intermediate.details,
             intermediate.signature,
             @certificate_public_key
           ) do
      :ok
    else
      _invalid -> {:error, :invalid_noise_certificate}
    end
  rescue
    _error -> {:error, :invalid_noise_certificate}
  end

  defp client_payload(%Credentials{me: nil} = credentials, options) do
    Payload.registration(credentials, options)
  end

  defp client_payload(credentials, options), do: Payload.login(credentials, options)

  defp valid_certificate?(certificate) do
    not is_nil(certificate) and is_binary(certificate.details) and
      byte_size(certificate.details) > 0 and is_binary(certificate.signature) and
      byte_size(certificate.signature) == 64
  end
end
