defmodule Scrape.Website do
  @moduledoc """
  Every function in this module takes an HTML string, and returns some
  data extracted from it, mostly strings. Floki is used for parsing
  the raw HTML.

  Usually, we want some general metadata from websites, not a deep text
  analysis or the like. Since this is the foundation of a web crawler
  in the future, the used algorithms should be as fast as possible, even
  when the resulting quality suffers a little.
  """

  alias Scrape.Website
  alias Scrape.Exquery
  alias Scrape.Link
  alias Httpoison

  defstruct valid: "", type: "", title: "", description: "", url: "", image: "", favicon: "",
    feeds: [], tags: [], twitter_accounts: []

  @spec parse(String.t, String.t) :: %Website{}
  def parse(html, url) do
    %Scrape.Website{
      url: url,
      valid: validate_url(url),
      type: find_type(html),
      title: find_title(html),
      description: find_description(html),
      image: find_image(html),
      favicon: find_favicon(html),
      twitter_accounts: find_twitter_accounts(html),
      feeds: find_feeds(html),
      tags: find_tags(html)
    }
    |> find_canonical(html)
    |> normalize_urls
  end

  @doc """
    Returns if the URL is VALID/INVALID
  """
  @spec validate_url(String.t) :: String.t
  def validate_url(url) do
    case HTTPoison.get(url) do
      {:ok, _body}      -> "valid"
      {:error, _reason} -> "invalid"
    end
  end

  @doc """
    Returns the title of a HTML site
  """
  @spec find_title(String.t) :: String.t
  def find_title(html) do
    title = Exquery.find html, "title", :longest
    rx = ~r/\s[|-].{1}.+$/

    if title && String.match?(title, rx) do
      title
      |> String.split(rx)
      |> List.first
    else
      title
    end
  end

  @doc """
    Returns the type of a HTML site
  """
  @spec find_type(String.t) :: String.t
  def find_type(html) do

    selector = """
      meta[property='og:type'],
      meta[name='twitter:type'],
      meta[name='type']
    """

    Exquery.attr html, selector, "content", :longest

  end

  @doc """
    Returns the description of a HTML site
  """
  @spec find_description(String.t) :: String.t
  def find_description(html) do
    selector = """
      meta[property='og:description'],
      meta[name='twitter:description'],
      meta[name='description']
    """

    Exquery.attr html, selector, "content", :longest
  end

  @doc """
    Returns the main image url of a HTML site
  """
  @spec find_image(String.t) :: String.t
  def find_image(html) do
    selector = """
      meta[property='og:image'],
      meta[name='twitter:image']
    """

    Exquery.attr html, selector, "content", :first
  end

  @doc """
    Returns the favicon url of a HTML site
  """
  @spec find_favicon(String.t) :: String.t
  def find_favicon(html) do
    selector = """
      link[rel='apple-touch-icon'],
      link[rel='apple-touch-icon-precomposed'],
      link[rel='shortcut icon'],
      link[rel='icon']
    """

    favicon = Exquery.attr html, selector, "href", :longest

    if favicon do
      favicon
    else
      Exquery.attr html,
        "meta[name='msapplication-TileImage']",
	      "content",
        :first
    end
  end

  @doc """
    Returns a list of feed urls for a HTML site
  """
  @spec find_feeds(String.t) :: [String.t]
  def find_feeds(html) do
    selector = """
      link[type='application/rss+xml'],
      link[type='application/atom+xml'],
      link[rel='alternate']
    """

    feeds = Exquery.attr(html, selector, "href", :all)

    if length(feeds) > 0 do
      feeds
    else
      Regex.scan(~r{href=['"]([^'"]*(rss|atom|feed|xml)[^'"]*)['"]},
        html,
        capture: :all_but_first)
      |> Enum.map(fn matches -> List.first(matches) end)
    end
  end

  @doc """
  Returns a list of twitter urls for a HTML site
  """
  @spec find_twitter_accounts(String.t) :: [String.t]
  def find_twitter_accounts(html) do
    selector = """
    meta[property="twitter:site"],
    meta[name="twitter:site"]
    """

    accounts = Exquery.attr(html, selector, "content", :all)

    if length(accounts) > 0 do
      accounts
    else
      Regex.scan(~r{href=['"]([^'"]*(twitter.com/[A-Za-z0-9_]+)["'])},
                                     html,
                                     capture: :all_but_first)
                                     |> Enum.map(fn [_ | [match]] -> match end)
                                     |> Enum.map(fn match -> String.replace(match, "twitter.com/", "@") end)
                                     |> Enum.uniq
    end
  end

  @doc """
    Fetch the meta-keywords if exists
  """
  @spec find_tags(String.t) :: [%{name: String.t, accuracy: float}]
  def find_tags(html) do
    html
    |> Exquery.attr("meta[name=keywords]", "content", :all)
    |> split_phrases
    |> Enum.map(fn s -> s |> String.trim |> String.downcase end)
    |> Enum.map(fn s -> %{name: s, accuracy: 0.6} end)
  end

  defp split_phrases([]), do: []
  defp split_phrases(list, results \\ [])
  defp split_phrases([], results), do: results
  defp split_phrases([h | t], results) do
    if String.contains?(h, [";", ",", "|"]) do
      split_phrases t, results ++ String.split(h, ~r/[;,|]/, trim: true)
    else
      split_phrases t, [h | results]
    end
  end

  @doc """
    Look for a canonical url and use it, choose the given URL otherwise
  """
  @spec find_canonical(%Website{}, String.t) :: %Website{}
  def find_canonical(website, html) do
    canonical = Exquery.attr html, "link[rel=canonical]", "href"

    if !canonical || String.length(canonical) < 3 do
      %{website | url: verify_and_add_scheme(website.url)}
    else
      %{website | url: canonical}
    end
  end

  @doc """
    Iterate over all URLs in the website object and expand them to absolute
    ones
  """
  @spec normalize_urls(%Website{}) :: %Website{}
  def normalize_urls(website) do
    website
    |> put_lazy(:image, fn(w) -> Link.expand(w.image, w.url) end)
    |> put_lazy(:favicon, fn(w) -> Link.expand(w.favicon, w.url) end)
    |> put_lazy(:feeds, fn(w) ->
      w.feeds
      |> Enum.map(fn(feed) -> feed |> Link.expand(w.url) end)
      |> Enum.filter(&url_is_feed?/1)
    end)
  end

  @doc """
  Check if input URL specifies http or https scheme.
  If not, it has to be added (http by default)
  """
  def verify_and_add_scheme(url) do
    if(url_has_scheme?(url)) do
      url
    else
      "http://#{url}"
    end
  end

  defp url_has_scheme?(url) do
    case URI.parse url do
      %URI{ host: nil, scheme: nil} -> false
        _ -> true
    end
  end

  defp url_is_feed?(url) do
    parsed_url = URI.parse url
    (String.contains?(url, ["http://", "https://"])) &&
    (!String.ends_with?(url, [".html", ".png", ".jpg", ".gif"])) &&
    (parsed_url.path != "/" || parsed_url.query != nil) &&
    (parsed_url.path != "") &&
    (!String.contains?(url, ["comment", "comments", "target="])) &&
    (!String.contains?(url, "android-app:"))
  end

  defp put_lazy(website, key, fun) do
    if Map.get(website, key) do
      Map.put website, key, fun.(website)
    else
      website
    end
  end
end
