defmodule Baileys.Protocol.Browser do
  @moduledoc false

  @type preset :: :web | :windows_desktop

  @enforce_keys [
    :preset,
    :os,
    :name,
    :platform_type,
    :companion_platform_id,
    :web_sub_platform,
    :sync_full_history?
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          preset: preset(),
          os: String.t(),
          name: String.t(),
          platform_type: :CHROME | :DESKTOP,
          companion_platform_id: String.t(),
          web_sub_platform: :WEB_BROWSER | :WIN_HYBRID,
          sync_full_history?: boolean()
        }

  @spec resolve(keyword()) :: {:ok, t()} | {:error, atom()}
  def resolve(options) when is_list(options) do
    with {:ok, browser} <- browser_option(Keyword.get(options, :browser, :web)),
         {:ok, sync_full_history?} <-
           boolean_option(Keyword.get(options, :sync_full_history, false)),
         :ok <- validate_full_history(browser, sync_full_history?) do
      {:ok, build(browser, sync_full_history?)}
    end
  end

  def resolve(_options), do: {:error, :invalid_browser_options}

  @spec resolve!(keyword()) :: t()
  def resolve!(options) do
    case resolve(options) do
      {:ok, browser} -> browser
      {:error, reason} -> raise ArgumentError, "invalid browser options: #{inspect(reason)}"
    end
  end

  defp browser_option(browser) when browser in [:web, :windows_desktop], do: {:ok, browser}
  defp browser_option(_browser), do: {:error, :invalid_browser}

  defp boolean_option(value) when is_boolean(value), do: {:ok, value}
  defp boolean_option(_value), do: {:error, :invalid_sync_full_history}

  defp validate_full_history(:windows_desktop, _sync_full_history?), do: :ok
  defp validate_full_history(:web, false), do: :ok

  defp validate_full_history(:web, true),
    do: {:error, :sync_full_history_requires_windows_desktop}

  defp build(:web, false) do
    %__MODULE__{
      preset: :web,
      os: "Mac OS",
      name: "Chrome",
      platform_type: :CHROME,
      companion_platform_id: "1",
      web_sub_platform: :WEB_BROWSER,
      sync_full_history?: false
    }
  end

  defp build(:windows_desktop, sync_full_history?) do
    %__MODULE__{
      preset: :windows_desktop,
      os: "Windows",
      name: "Desktop",
      platform_type: :DESKTOP,
      companion_platform_id: "8",
      web_sub_platform: if(sync_full_history?, do: :WIN_HYBRID, else: :WEB_BROWSER),
      sync_full_history?: sync_full_history?
    }
  end
end
