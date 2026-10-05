unit uNewsFeed;
(*
  News feed for the launcher right-hand panel.
  Fetches the official launcher's news list for a product and surface it in the UI.

  Source: GET https://nxl.nxfs.nexon.com/news/regions/1/<product>/en-US/list.json
          -> JSON array of news items:
             {"Id":N,"Category":"maintenance|events|sales|updates|announcements|community",
              "Title":"...","Summary":"...","LiveDate":"YYYY-MM-DDTHH:MM:SSZ",
              "ImageThumbnail2":"https://..."}

  Public endpoint — no auth required. Only used for display; never for launch/licensing.
*)

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.DateUtils, System.Generics.Collections,
  System.IOUtils, Vcl.Graphics;

type
  TNewsCategory = (
    ncMaintenance,
    ncEvents,
    ncSales,
    ncUpdates,
    ncAnnouncements,
    ncCommunity,
    ncUnknown
  );

  TNewsItem = record
    Id:        Int64;
    Category:  TNewsCategory;
    CategoryName: string;   // raw string from server
    Title:     string;
    Summary:   string;
    LiveDate:  TDateTime;   // local time (server UTC converted)
    Thumbnail: string;
    IsMaintenance: Boolean; // maintenance that is NOT [COMPLETED] / not in the past
  end;

  TNewsList = TArray<TNewsItem>;

function FetchNews(ProductId: Integer): TNewsList;
function NewsCategoryToStr(const C: TNewsCategory): string;
function NewsCategoryColor(const C: TNewsCategory): TColor;

// Accent colour for a specific feed item. Overrides the category colour for:
//   - Announcements  -> grey/silver
//   - CURRENT maintenance (no [COMPLETED] tag) -> red
//   - everything else -> the category colour (events/sales/updates/community).
// A maintenance notice is "current" when its title does not start with [COMPLETED].
function NewsItemAccent(const Item: TNewsItem): TColor;
function NewsItemIsCurrentMaintenance(const Item: TNewsItem): Boolean;

// Local disk cache for the news feed, so the launcher can render instantly on
// the next start without waiting on the network. Cache lives in %APPDATA%\Rua\.
// LoadNewsCache returns cached items (empty if none/expired/missing).
// SaveNewsCache writes the given items to disk, stamped with the current time.
// RefreshDue returns True when the cached copy is older than MaxAgeMinutes.
function NewsCachePath(ProductId: Integer): string;
function LoadNewsCache(ProductId: Integer): TNewsList;
procedure SaveNewsCache(ProductId: Integer; const News: TNewsList);
function NewsCacheRefreshDue(const News: TNewsList; ProductId: Integer;
  MaxAgeMinutes: Integer = 30): Boolean;

implementation

uses
  System.Net.HttpClient;

const
  NEWS_URL = 'https://nxl.nxfs.nexon.com/news/regions/1/%d/en-US/list.json';
  NEWS_UA  = 'NexonLauncher.nxl-release-18.14.10-220-fc7480c-coreapp-3.3.0';

function NewsCategoryFromStr(const S: string): TNewsCategory;
begin
  if      SameText(S, 'maintenance')  then Result := ncMaintenance
  else if SameText(S, 'events')       then Result := ncEvents
  else if SameText(S, 'sales')        then Result := ncSales
  else if SameText(S, 'updates')      then Result := ncUpdates
  else if SameText(S, 'announcements') then Result := ncAnnouncements
  else if SameText(S, 'community')    then Result := ncCommunity
  else Result := ncUnknown;
end;

function NewsCategoryToStr(const C: TNewsCategory): string;
begin
  case C of
    ncMaintenance:   Result := 'Maintenance';
    ncEvents:        Result := 'Events';
    ncSales:         Result := 'Sales';
    ncUpdates:       Result := 'Updates';
    ncAnnouncements: Result := 'Announcements';
    ncCommunity:     Result := 'Community';
  else
    Result := 'News';
  end;
end;

function NewsCategoryColor(const C: TNewsCategory): TColor;
begin
  case C of
    ncMaintenance:   Result := TColor($002A87E0); // orange  (R=E0 G=87 B=2A)
    ncEvents:        Result := TColor($00D9904A); // blue    (R=4A G=90 B=D9)
    ncSales:         Result := TColor($006CA82E); // green   (R=2E G=A8 B=6C)
    ncUpdates:       Result := TColor($00D94A7A); // purple  (R=7A G=4A B=D9)
    ncAnnouncements: Result := TColor($002B39C0); // red     (R=C0 G=39 B=2B)
    ncCommunity:     Result := TColor($00BA8B57); // steel   (R=57 G=8B B=BA)
  else
    Result := TColor($00888888); // grey
  end;
end;

function NewsItemIsCurrentMaintenance(const Item: TNewsItem): Boolean;
begin
  // A maintenance notice is "current" (live) when its title does not carry the
  // [COMPLETED] marker. Past/completed ones get a neutral accent instead.
  Result := (Item.Category = ncMaintenance)
        and (Pos('[COMPLETED]', Item.Title) = 0);
end;

function NewsItemAccent(const Item: TNewsItem): TColor;
begin
  if NewsItemIsCurrentMaintenance(Item) then
    Result := TColor($002B39C0) // red — live/active maintenance
  else if Item.Category = ncMaintenance then
    Result := TColor($00B8B8B8) // grey/silver — completed (finished) maintenance
  else if Item.Category = ncAnnouncements then
    Result := TColor($00B8B8B8) // grey/silver — announcements
  else
    Result := NewsCategoryColor(Item.Category);
end;

// Convert ISO-8601 (UTC, e.g. 2026-08-28T15:00:00Z) to local TDateTime; 0 on failure.
function ParseIsoDate(const S: string): TDateTime;
var
  Y, Mo, D, H, Mi, Se: Word;
begin
  Result := 0;
  if Length(S) < 19 then Exit;
  try
    Y  := StrToInt(Copy(S, 1, 4));
    Mo := StrToInt(Copy(S, 6, 2));
    D  := StrToInt(Copy(S, 9, 2));
    H  := StrToInt(Copy(S, 12, 2));
    Mi := StrToInt(Copy(S, 15, 2));
    Se := StrToInt(Copy(S, 18, 2));
    Result := EncodeDate(Y, Mo, D) + EncodeTime(H, Mi, Se, 0);
  except
    Result := 0;
  end;
end;

function FetchNews(ProductId: Integer): TNewsList;
var
  Http: THTTPClient;
  Resp: IHTTPResponse;
  JArr: TJSONArray;
  J:    TJSONObject;
  Item: TNewsItem;
  Title, Summary, CatStr, DateStr: string;
  I:    Integer;
begin
  SetLength(Result, 0);
  Http := THTTPClient.Create;
  try
    Http.CookieManager := nil;
    Http.CustomHeaders['User-Agent'] := NEWS_UA;
    Http.CustomHeaders['Accept']     := 'application/json, text/plain, */*';
    // Optional revalidation; the list.json ETag changes only when new notices land.
    Resp := Http.Get(Format(NEWS_URL, [ProductId]));
    if Resp.StatusCode <> 200 then Exit;

    JArr := TJSONObject.ParseJSONValue(Resp.ContentAsString) as TJSONArray;
    if JArr = nil then Exit;
    try
      SetLength(Result, JArr.Count);
      I := 0;
      for var V in JArr do
      begin
        if not (V is TJSONObject) then Continue;
        J := V as TJSONObject;
        // Read Id as Int64 via TJSONNumber (GetValue<Int64> can interpret a
        // negative number incorrectly / fall back to 0 on some Delphi builds).
        var IdNum := J.GetValue('Id') as TJSONNumber;
        if IdNum <> nil then Item.Id := IdNum.AsInt64 else Item.Id := 0;
        CatStr         := J.GetValue<string>('Category', '');
        Item.CategoryName := CatStr;
        Item.Category  := NewsCategoryFromStr(CatStr);
        Title          := J.GetValue<string>('Title', '');
        Summary        := J.GetValue<string>('Summary', '');
        DateStr        := J.GetValue<string>('LiveDate', '');
        Item.Title     := Title;
        Item.Summary   := Summary;
        Item.LiveDate  := ParseIsoDate(DateStr);
        Item.Thumbnail := J.GetValue<string>('ImageThumbnail2', '');
        Item.IsMaintenance := (Item.Category = ncMaintenance);
        Result[I]      := Item;
        Inc(I);
      end;
      SetLength(Result, I);
    finally
      JArr.Free;
    end;
  finally
    Http.Free;
  end;
end;

function NewsCachePath(ProductId: Integer): string;
begin
  Result := TPath.Combine(GetEnvironmentVariable('APPDATA'), 'Rua');
  TDirectory.CreateDirectory(Result);
  Result := TPath.Combine(Result, Format('news_%d.json', [ProductId]));
end;

function LoadNewsCache(ProductId: Integer): TNewsList;
var
  Path: string;
  JArr: TJSONArray;
  J:    TJSONObject;
  Item: TNewsItem;
  I:    Integer;
begin
  SetLength(Result, 0);
  Path := NewsCachePath(ProductId);
  if not TFile.Exists(Path) then Exit;

  try
    JArr := TJSONObject.ParseJSONValue(
      TEncoding.UTF8.GetString(TFile.ReadAllBytes(Path))) as TJSONArray;
  except
    Exit;
  end;
  if JArr = nil then Exit;

  try
    for I := 0 to JArr.Count - 1 do
    begin
      J := JArr.Items[I] as TJSONObject;
      if J = nil then Continue;
      var IdNum := J.GetValue('Id') as TJSONNumber;
      if IdNum <> nil then Item.Id := IdNum.AsInt64 else Item.Id := 0;
      Item.CategoryName  := J.GetValue<string>('cat', '');
      Item.Category      := NewsCategoryFromStr(Item.CategoryName);
      Item.Title         := J.GetValue<string>('title', '');
      Item.Summary       := J.GetValue<string>('summary', '');
      Item.LiveDate      := J.GetValue<Double>('date', 0);
      Item.Thumbnail     := J.GetValue<string>('thumb', '');
      Item.IsMaintenance := J.GetValue<Boolean>('maint', False);
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Item;
    end;
  finally
    JArr.Free;
  end;
end;

procedure SaveNewsCache(ProductId: Integer; const News: TNewsList);
var
  JArr: TJSONArray;
  J:    TJSONObject;
  I:    Integer;
begin
  JArr := TJSONArray.Create;
  try
    for I := 0 to High(News) do
    begin
      J := TJSONObject.Create;
      J.AddPair('id',      TJSONNumber.Create(News[I].Id));
      J.AddPair('cat',     News[I].CategoryName);
      J.AddPair('title',   News[I].Title);
      J.AddPair('summary', News[I].Summary);
      J.AddPair('date',    News[I].LiveDate);
      J.AddPair('thumb',   News[I].Thumbnail);
      J.AddPair('maint',   News[I].IsMaintenance);
      JArr.Add(J);
    end;
    TFile.WriteAllText(NewsCachePath(ProductId), JArr.ToJSON, TEncoding.UTF8);
  finally
    JArr.Free;
  end;
end;

function NewsCacheRefreshDue(const News: TNewsList; ProductId: Integer;
  MaxAgeMinutes: Integer): Boolean;
var
  Path: string;
  I:   Integer;
begin
  // No cached data → refresh.
  if Length(News) = 0 then Exit(True);
  // Cache written when ids failed to parse (all 0) → stale, force refresh.
  for I := 0 to High(News) do
    if News[I].Id <> 0 then
    begin
      Result := False;
      Break;
    end;
  if I > High(News) then Exit(True);  // every id was 0 → force refresh

  // File last-modify time is the freshness stamp.
  Path := NewsCachePath(ProductId);
  if (not TFile.Exists(Path)) or
     (MinutesBetween(Now, TFile.GetLastWriteTime(Path)) >= MaxAgeMinutes) then
    Exit(True);
  Result := False;
end;

end.
