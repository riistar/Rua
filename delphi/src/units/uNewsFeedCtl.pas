unit uNewsFeedCtl;
{
  TNewsFeed — a themed news-feed component (TScrollBox of stacked news cards).

  Replaces the launcher's static hero image with a live list of news rows for a
  product. All card rendering, VCL theme colours, category colour-coding and
  click behaviour is owned here; the owner form just calls SetNews(Items).

  Layout per card: [category accent bar][category chip][title (ellipsis)...... ][date]
  The category chip column width is fixed (widest category label + padding) so the
  chips align vertically across all rows. Titles are trimmed with an ellipsis and are
  clickable (open the news hub). Row background + text colours come from
  Vcl.Themes.StyleServices, so the feed follows the active VclStyle (dark or light).
}

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, System.Types, System.DateUtils,
  Winapi.Windows, Winapi.Messages,
  Vcl.Controls, Vcl.Forms, Vcl.ExtCtrls, Vcl.StdCtrls, Vcl.Graphics, Vcl.Themes,
  uNewsFeed;

type
  // Thread-safe prepared card data (no VCL handles). Computed on a worker thread,
  // then used to create the actual controls on the main thread.
  TNewsCardPrep = record
    ChipText:   string;
    ChipColor:  TColor;
    Bg:         TColor;
    Title:      string;   // ellipsized
    TitleColor: TColor;
    Summary:    string;   // ellipsized ('' if none)
    SummaryColor: TColor;
    DateText:   string;   // '' if none
    DateColor:  TColor;
    IsMaintenance: Boolean;
    Url:        string;   // built article URL ('' → fall back to the hub)
  end;

  TNewsFeed = class(TScrollBox)
  private
    FView:    TArray<TNewsItem>;     // filtered (LookbackDays) view
    FHubUrl:  string;
    FChips:   TArray<TPanel>;        // card panels (rebuilt on SetNews)
    FDark:    Boolean;               // active style is dark (drives text/tint choices)
    FBase:    TColor;                // real themed panel background colour
    FBuildThread: TThread;           // background prep thread (news data only)
    FBuildToken:  Integer;           // guards against stale thread results
    FLastToken:   Integer;           // token of the "current" build (for OnTerminate)
    FPrep:        TArray<TNewsCardPrep>; // prepared card data from the worker
    FChipW:       Integer;           // measured chip column width (from worker)
    FOnOpenNews: TNotifyEvent;
    FOnEmpty:    TNotifyEvent;
    procedure DoTitleClick(Sender: TObject);
    procedure CMStyleChanged(var Message: TMessage); message CM_STYLECHANGED;
    procedure BuildCards;            // create controls from FPrep (main thread)
    procedure PrepTerminated(Sender: TObject); // main-thread completion callback
  protected
    procedure Loaded; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor  Destroy; override;
    procedure SetNews(const ANews: TArray<TNewsItem>; LookbackDays: Integer = 60);
    property NewsHubUrl: string read FHubUrl write FHubUrl;
    property OnOpenNews: TNotifyEvent read FOnOpenNews write FOnOpenNews;
    property OnEmpty:    TNotifyEvent read FOnEmpty   write FOnEmpty;
    procedure RefreshLook;
    function  CurrentCount: Integer;  // number of visible cards
  end;

implementation

uses
  Winapi.ShellAPI;

const
  DEFAULT_HUB = 'https://www.nexon.com/mabinogi/news';
  CARD_H   = 56;
  PAD      = 10;
  DateWConst = 72;

// Thread-safe text ellipsization: trim `Text` to fit `MaxWidth` at `FontSize`
// (bold or not) using a measured TBitmap. No VCL handles involved.
function Ellipsize(const Text, FontName: string; FontSize: Integer;
  Bold: Boolean; MaxWidth: Integer): string;
var
  Bmp: TBitmap;
  S: string;
begin
  Bmp := TBitmap.Create;
  try
    Bmp.Canvas.Font.Name  := FontName;
    Bmp.Canvas.Font.Size  := FontSize;
    Bmp.Canvas.Font.Style := [];
    if Bold then Bmp.Canvas.Font.Style := [fsBold];
    S := Text;
    if Bmp.Canvas.TextWidth(S) > MaxWidth then
    begin
      while (S <> '') and (Bmp.Canvas.TextWidth(S + '...') > MaxWidth) do
        Delete(S, Length(S), 1);
      S := S + '...';
    end;
    Result := S;
  finally
    Bmp.Free;
  end;
end;

// Measure the pixel height of `Text` wrapped into `MaxWidth` px at the given
// Canvas font (uses DrawText DT_CALCRECT, which honours word wrap).
function WrappedTextHeight(ACanvas: TCanvas; const Text: string; MaxWidth: Integer): Integer;
var
  R: TRect;
  Flags: UINT;
begin
  R := Rect(0, 0, MaxWidth, 0);
  Flags := DT_CALCRECT or DT_LEFT or DT_TOP or DT_WORDBREAK or DT_NOPREFIX;
  DrawTextW(ACanvas.Handle, PChar(Text), -1, R, Flags);
  Result := R.Bottom - R.Top;
  if Result <= 0 then Result := 16;
end;

// Build an article-style news URL from a feed item's CMS Id and title, e.g.
//   Id=-44611, Title="[COMPLETED] Unscheduled Maintenance - August 28th"
//   -> https://www.nexon.com/mabinogi/news/44611/completed-unscheduled-maintenance-august-28th
function BuildNewsUrl(Id: Int64; const Title: string): string;
var
  S, Slug: string;
  Ch: Char;
  IdAbs: Int64;
begin
  if Id >= 0 then IdAbs := Id else IdAbs := -Id;

  Slug := '';
  S := LowerCase(Title);
  // Strip leading "[tag] " markers so they don't appear in the slug.
  while (S <> '') and (S[1] = '[') do
  begin
    var P := Pos(']', S);
    if P = 0 then Break;
    S := Trim(Copy(S, P + 1, MaxInt));
  end;
  for Ch in S do
  begin
    if (Ch >= 'a') and (Ch <= 'z') then Slug := Slug + Ch
    else if (Ch >= '0') and (Ch <= '9') then Slug := Slug + Ch
    else if Slug <> '' then
      // Separator → single '-', skipping if the slug already ends in one.
      if Slug[Length(Slug)] <> '-' then Slug := Slug + '-';
  end;
  while (Slug <> '') and (Slug[Length(Slug)] = '-') do
    Delete(Slug, Length(Slug), 1);

  if Slug = '' then
    Result := 'https://www.nexon.com/mabinogi/news'
  else
    Result := 'https://www.nexon.com/mabinogi/news/' + IntToStr(IdAbs) + '/' + Slug;
end;

// Linear mix of two TColors by Amount (0..1).
function MixColor(const A, B: TColor; Amount: Single): TColor;
var
  Ar, Ag, Ab: Byte;
  Br, Bg, Bb: Byte;
begin
  Ar := Byte(A);        Ag := Byte(A shr 8);        Ab := Byte(A shr 16);
  Br := Byte(B);        Bg := Byte(B shr 8);        Bb := Byte(B shr 16);
  Ar := Round(Ar + (Br - Ar) * Amount);
  Ag := Round(Ag + (Bg - Ag) * Amount);
  Ab := Round(Ab + (Bb - Ab) * Amount);
  Result := TColor(Ar or (Ag shl 8) or (Ab shl 16));
end;

// Sample the ACTUAL painted themed background by WM_PRINTing the parent panel into
// a bitmap and reading a pixel. This is the only reliable way to get a skinned
// theme's real bg — GetSystemColor returns OS defaults, and the panel element
// draws transparently. PRF_CLIENT paints the parent's own background (not children).
function ThemedPanelColor(AWidget: TWinControl): TColor;
const
  PRF_CLIENT      = $00000004;
  PRF_ERASEBKGND  = $00000008;
  W = 8;
  H = 8;
var
  Bmp: TBitmap;
  P:   TWinControl;
begin
  Result := clBtnFace;
  P := AWidget.Parent;
  if (P = nil) or (not P.HandleAllocated) then Exit; // parent not ready yet

  Bmp := TBitmap.Create;
  try
    Bmp.PixelFormat := pf24bit;
    Bmp.SetSize(W, H);
    SendMessage(P.Handle, WM_PRINT, Bmp.Canvas.Handle,
                PRF_CLIENT or PRF_ERASEBKGND);
    Result := Bmp.Canvas.Pixels[1, 1];
  finally
    Bmp.Free;
  end;
end;

function IsLightColor(const C: TColor): Boolean;
var
  r, g, b: Integer;
begin
  r := Byte(C); g := Byte(C shr 8); b := Byte(C shr 16);
  Result := ((r * 299 + g * 587 + b * 114) div 1000) >= 150;
end;

// Pick a readable text colour for a given background.
function TextOn(const Bg: TColor): TColor;
begin
  if IsLightColor(Bg) then Result := $00322E26   // dark warm grey (on light tint)
                      else Result := clWhite;    // white (on strong tint)
end;

constructor TNewsFeed.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FHubUrl := DEFAULT_HUB;
  BorderStyle   := bsNone;
  BevelKind     := bkNone;
  DoubleBuffered := True;
  VertScrollBar.Tracking := True;
  VertScrollBar.Smooth   := True;
  // RefreshLook is deferred to Loaded / CM_STYLECHANGED — the parent handle and
  // active VCL style aren't ready during construction (avoids a white flash).
end;

destructor TNewsFeed.Destroy;
var
  I: Integer;
begin
  Inc(FBuildToken);                 // invalidate any in-flight worker
  if FBuildThread <> nil then
  begin
    FBuildThread.Terminate;
    FBuildThread := nil;            // detached; token prevents stale queue posting
  end;
  for I := 0 to Length(FChips) - 1 do
    FChips[I].Free;
  SetLength(FChips, 0);
  inherited;
end;

procedure TNewsFeed.RefreshLook;
var
  Bg: TColor;
begin
  // Sample the true themed panel background (dark on dark style, light on light).
  Bg := ThemedPanelColor(Self);
  FBase := Bg;
  FDark := not IsLightColor(Bg);

  StyleElements := [seClient, seFont, seBorder]; // follow the active style bg/text
  Color := Bg;
end;

procedure TNewsFeed.Loaded;
begin
  inherited;
  RefreshLook;
end;

function TNewsFeed.CurrentCount: Integer;
begin
  Result := Length(FView);
end;

procedure TNewsFeed.SetNews(const ANews: TArray<TNewsItem>; LookbackDays: Integer);
var
  Token, CW: Integer;
begin
  Inc(FBuildToken);
  Token := FBuildToken;
  CW := ClientWidth;   // read on main thread; used for exact text-width ellipsization

  // Cancel any in-flight prep thread (it will see a stale token and skip).
  if FBuildThread <> nil then
  begin
    FBuildThread.Terminate;
    FBuildThread := nil;   // detached; stale result guarded by the token
  end;

  // Sample the theme on the main thread (VCL + Canvas access).
  RefreshLook;

  // --- Worker thread: sort, filter, measure text, compute colours/layout ---
  // All data-only; no VCL control creation (that stays on the main thread).
  FBuildThread := TThread.CreateAnonymousThread(procedure
  var
    Items, View: TArray<TNewsItem>;
    Prep: TArray<TNewsCardPrep>;
    I, J: Integer;
    ChipW: Integer;
    Cat: string;
    Meas: TBitmap;
    Bg, SubCol, TextCol: TColor;
    It: TNewsItem;
    P: TNewsCardPrep;
  begin
    // Bail if superseded before we do any work.
    if FBuildToken <> Token then Exit;

    Items := ANews;

    // Newest first.
    for I := High(Items) downto 1 do
      for J := 0 to I - 1 do
        if Items[J].LiveDate < Items[J + 1].LiveDate then
        begin
          var Tmp := Items[J];
          Items[J] := Items[J + 1];
          Items[J + 1] := Tmp;
        end;

    // Filter to the look-back window.
    SetLength(View, 0);
    for I := 0 to High(Items) do
      if DaysBetween(Now, Items[I].LiveDate) <= LookbackDays then
      begin
        SetLength(View, Length(View) + 1);
        View[High(View)] := Items[I];
      end;

    if FBuildToken <> Token then Exit; // superseded during filter

    // Measure the category chip column on a TBitmap (has a real DC).
    Meas := TBitmap.Create;
    try
      Meas.Canvas.Font.Name  := 'Segoe UI';
      Meas.Canvas.Font.Size  := 8;
      Meas.Canvas.Font.Style := [fsBold];
      ChipW := 0;
      for I := 0 to High(View) do
      begin
        Cat := NewsCategoryToStr(View[I].Category);
        var W := Meas.Canvas.TextWidth(Cat);
        if W > ChipW then ChipW := W;
      end;
      ChipW := ChipW + 16;
      if ChipW < 64 then ChipW := 64;
    finally
      Meas.Free;
    end;

    // Prepare each card (ellipsize text, compute colours) — no controls created.
    SetLength(Prep, Length(View));
    for I := 0 to High(View) do
    begin
      It := View[I];
      P.IsMaintenance := NewsItemIsCurrentMaintenance(It);
      var Accent: TColor := NewsItemAccent(It);   // per-item accent (announcements grey, current maint red)
      P.ChipText   := NewsCategoryToStr(It.Category);
      P.ChipColor  := Accent;
      // Bulma/Primer "light" notification style, adapted per active VCL style:
      // light style -> pale tint over white w/ dark saturated text; dark style
      // -> pale tint over the real themed panel colour w/ light saturated text.
      if FDark then
      begin
        Bg           := MixColor(FBase, Accent, 0.14);
        P.Bg         := Bg;
        TextCol      := TextOn(Bg);
        if P.IsMaintenance then
          P.TitleColor := Accent
        else
          P.TitleColor := MixColor(Accent, clWhite, 0.45);
        SubCol       := MixColor(TextCol, Bg, 0.45);
      end
      else
      begin
        Bg           := MixColor(clWhite, Accent, 0.15);
        P.Bg         := Bg;
        TextCol      := TextOn(Bg);
        // Pale accents (grey/silver, blue) vanish on a pale tint, so darken the
        // accent toward black for both the category label and the title.
        P.ChipColor  := MixColor(Accent, clBlack, 0.45);
        P.TitleColor := MixColor(Accent, clBlack, 0.68);
        SubCol       := MixColor(TextCol, Bg, 0.25);
      end;
      P.SummaryColor := SubCol;
      P.DateColor  := SubCol;

      // Ellipsize title to width; keep the summary FULL so it can word-wrap and
      // the card grows (height is computed on the main thread in BuildCards).
      var WidthForText := CW - PAD - ChipW - PAD - DateWConst - PAD;
      if WidthForText < 40 then WidthForText := 40;
      P.Title   := Ellipsize(It.Title, 'Segoe UI', 9, True,  WidthForText);
      P.Summary := It.Summary;
      if It.LiveDate > 0 then
        P.DateText := FormatDateTime('dd mmm', It.LiveDate)
      else
        P.DateText := '';

      // Build the article URL: /mabinogi/news/<abs(Id)>/<slugified-title>.
      P.Url := BuildNewsUrl(It.Id, It.Title);

      Prep[I] := P;
    end;

    if FBuildToken <> Token then Exit;

    // Store prepared data; PrepTerminated (main thread) creates the controls.
    FView   := View;
    FPrep   := Prep;
    FChipW  := ChipW;
  end);
  FLastToken := Token;
  FBuildThread.OnTerminate := PrepTerminated;
  FBuildThread.Start;
end;

// Main-thread callback after the prep worker finishes: create the controls.
// Guard against stale threads (a newer SetNews bumped FBuildToken).
procedure TNewsFeed.PrepTerminated(Sender: TObject);
begin
  FBuildThread := nil;
  if FBuildToken <> FLastToken then Exit;   // stale result — ignore
  BuildCards;
end;

// Create/replace the card controls from the prepared data (main thread only).
procedure TNewsFeed.BuildCards;
var
  I: Integer;
  Card: TPanel;
  LblCat, LblTitle, LblSummary, LblDate: TLabel;
  TxX, TxW: Integer;
  P: TNewsCardPrep;
  CardH, SumH: Integer;
  Meas: TBitmap;
begin
  // Clear previous cards.
  for I := 0 to Length(FChips) - 1 do
    FChips[I].Free;
  SetLength(FChips, 0);

  if Length(FPrep) = 0 then
  begin
    if Assigned(FOnEmpty) then FOnEmpty(Self);
    Exit;
  end;

  Meas := TBitmap.Create;   // for measuring wrapped summary height (real DC)
  try
  // Build one card per item (stacked bottom-up). Cards grow tall to fit the
  // word-wrapped summary.
  for I := Length(FPrep) - 1 downto 0 do
  begin
    P := FPrep[I];

    TxX := PAD + FChipW + PAD;
    TxW := ClientWidth - TxX - DateWConst - PAD;

    // Measure the wrapped summary height first so we can size the card.
    SumH := 0;
    if P.Summary <> '' then
    begin
      Meas.Canvas.Font.Name  := 'Segoe UI';
      Meas.Canvas.Font.Size  := 8;
      Meas.Canvas.Font.Style := [];
      SumH := WrappedTextHeight(Meas.Canvas, P.Summary, TxW);
    end;

    // Base card: title row (18px) + gap + summary (SumH) + bottom padding.
    CardH := 6 + 18 + 4 + SumH + 8;
    if CardH < CARD_H then CardH := CARD_H;

    Card := TPanel.Create(Self);
    Card.Parent        := Self;
    Card.Height        := CardH;
    Card.Width         := ClientWidth;
    Card.Align         := alBottom;
    Card.BevelOuter    := bvNone;
    Card.TabOrder      := -1;
    Card.Margins.SetBounds(0, 0, 0, 0);
    Card.StyleElements := [seBorder]; // manual bg + font — style must not touch either
    Card.Color         := P.Bg;
    Card.Font.Color    := P.TitleColor;

    // Category label — coloured text only (no box; the row carries the tint).
    LblCat                 := TLabel.Create(Card);
    LblCat.Parent          := Card;
    LblCat.Left            := PAD;
    LblCat.Top             := 6;
    LblCat.AutoSize        := False;
    LblCat.Width           := FChipW;   // measured category column width from the worker
    LblCat.Height          := 18;
    LblCat.Alignment       := taLeftJustify;
    LblCat.Font.Style      := [fsBold];
    LblCat.Font.Size       := 9;
    LblCat.Font.Name       := 'Segoe UI';
    LblCat.Font.Color      := P.ChipColor;
    LblCat.ParentFont      := False;
    LblCat.StyleElements   := [];
    LblCat.Transparent     := True;
    LblCat.ShowAccelChar   := False;
    LblCat.Caption         := P.ChipText;

    // Title.
    LblTitle                := TLabel.Create(Card);
    LblTitle.Parent         := Card;
    LblTitle.Left           := TxX;
    LblTitle.Top            := 6;
    LblTitle.AutoSize       := False;
    LblTitle.Width          := TxW;
    LblTitle.Height         := 18;
    LblTitle.Font.Style     := [fsBold];
    LblTitle.Font.Size      := 9;
    LblTitle.Font.Name      := 'Segoe UI';
    LblTitle.Font.Color     := P.TitleColor;
    LblTitle.ParentFont     := False;
    LblTitle.StyleElements  := [];
    LblTitle.Transparent    := True;
    LblTitle.Cursor         := crHandPoint;
    if P.Url <> '' then
      LblTitle.Hint := P.Url
    else
      LblTitle.Hint := FHubUrl;
    LblTitle.ShowHint       := True;
    LblTitle.ShowAccelChar  := False;
    LblTitle.OnClick        := DoTitleClick;
    LblTitle.Caption        := P.Title;

    // Summary — word-wrapped, multi-line (card grows to fit).
    if P.Summary <> '' then
    begin
      LblSummary              := TLabel.Create(Card);
      LblSummary.Parent       := Card;
      LblSummary.Left         := TxX;
      LblSummary.Top          := 28;
      LblSummary.AutoSize     := False;
      LblSummary.Width        := TxW;
      LblSummary.Height       := SumH;
      LblSummary.WordWrap     := True;
      LblSummary.AutoSize     := False;
      LblSummary.Font.Style   := [];
      LblSummary.Font.Size    := 8;
      LblSummary.Font.Name    := 'Segoe UI';
      LblSummary.Font.Color   := P.SummaryColor;
      LblSummary.ParentFont   := False;
      LblSummary.StyleElements := [];
      LblSummary.Transparent  := True;
      LblSummary.ShowAccelChar := False;
      LblSummary.Alignment    := taLeftJustify;
      LblSummary.Caption      := P.Summary;
    end;

    // Date (right-aligned).
    if P.DateText <> '' then
    begin
      LblDate                := TLabel.Create(Card);
      LblDate.Parent         := Card;
      LblDate.AutoSize       := False;
      LblDate.Width          := DateWConst;
      LblDate.Height         := 18;
      LblDate.Top            := 6;
      LblDate.Left           := Card.Width - PAD - DateWConst;
      LblDate.Caption        := P.DateText;
      LblDate.Alignment      := taRightJustify;
      LblDate.Font.Size      := 9;
      LblDate.Font.Name      := 'Segoe UI';
      LblDate.Font.Color     := P.DateColor;
      LblDate.Transparent    := True;
      LblDate.ParentFont     := False;
      LblDate.StyleElements  := [];
      LblDate.ShowAccelChar  := False;
    end;

    SetLength(FChips, Length(FChips) + 1);
    FChips[High(FChips)] := Card;
  end;
  finally
    Meas.Free;
  end;
end;

procedure TNewsFeed.DoTitleClick(Sender: TObject);
var
  Url: string;
begin
  // The title label carries its article URL in Hint (built from Id + slug).
  if (Sender is TLabel) and (TLabel(Sender).Hint <> '') then
    Url := TLabel(Sender).Hint
  else
    Url := FHubUrl;
  ShellExecute(0, 'open', PChar(Url), nil, nil, 1); // SW_SHOWNORMAL
  if Assigned(FOnOpenNews) then
    FOnOpenNews(Self);
end;

// VCL sends CM_STYLECHANGED to all controls when the active style changes.
// Re-sample the themed background and rebuild the cards with the new colours.
procedure TNewsFeed.CMStyleChanged(var Message: TMessage);
begin
  inherited;
  RefreshLook;
  if Length(FView) > 0 then
    SetNews(FView, 60);   // rebuild cards against the new theme
end;

initialization
  System.Classes.RegisterClass(TNewsFeed);

end.
