unit uHeaderPageControl;

interface

uses
  Winapi.Windows, Winapi.Messages,
  System.Classes, System.Types, System.UITypes, System.Math,
  Vcl.Controls, Vcl.ComCtrls, Vcl.Graphics, Vcl.Imaging.Jpeg;

type
  // Horizontal alignment of the header image (used when not stretching/tiling).
  THeaderHorz = (hhLeft, hhCenter, hhRight);
  // Vertical alignment of the header image (used when not stretching/tiling).
  THeaderVert = (hvTop, hvMiddle, hvBottom);

  { THeaderPageControl
    Drop-in replacement for TPageControl.

    Adds:
      * HeaderHeight — the height of the tab strip (the band at the top the tabs
        live in), without enlarging the tab captions. 0 keeps the auto height.
      * HeaderImage  — a background picture drawn inside that band, behind the
        tab captions, so you no longer fight a TImage overlay with the layout.
    HeaderImageStretch fills the whole band, HeaderImageTile repeats the bitmap
    across the band, otherwise the bitmap is drawn at natural size positioned by
    HeaderHorizontal / HeaderVertical.

    When no image is assigned the control renders exactly like stock TPageControl
    (the tabs still owner-draw only when a header image is present). }
  THeaderPageControl = class(TPageControl)
  private
    FHeaderImage: TPicture;
    FHeaderImageVisible: Boolean;
    FHeaderImageStretch: Boolean;
    FHeaderImageTile: Boolean;
    FHeaderHorizontal: THeaderHorz;
    FHeaderVertical: THeaderVert;
    FHeaderHeight: Integer;
    FMinHeaderHeight: Integer;
    procedure SetHeaderImage(Value: TPicture);
    procedure SetHeaderHeight(Value: Integer);
    procedure ImageChanged(Sender: TObject);
    function StripRect: TRect;
    function ActiveTabStripHeight: Integer;
    function StretchSource(const ARect: TRect; const AImg: TBitmap): TRect;
    function AlignedDest(const AWidth, AHeight: Integer): TRect;
    procedure DrawStripImage(const ARect: TRect);
    procedure DrawTabContent(const ARect: TRect; AIndex: Integer; ASelected: Boolean);
  protected
    procedure DrawTab(AIndex: Integer; const ARect: TRect; ASelected: Boolean); override;
    procedure Loaded; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  published
    property HeaderHeight: Integer read FHeaderHeight write SetHeaderHeight default 0;
    property HeaderImage: TPicture read FHeaderImage write SetHeaderImage;
    property HeaderImageVisible: Boolean read FHeaderImageVisible write FHeaderImageVisible default True;
    property HeaderImageStretch: Boolean read FHeaderImageStretch write FHeaderImageStretch default True;
    property HeaderImageTile: Boolean read FHeaderImageTile write FHeaderImageTile default False;
    property HeaderHorizontal: THeaderHorz read FHeaderHorizontal write FHeaderHorizontal default hhCenter;
    property HeaderVertical: THeaderVert read FHeaderVertical write FHeaderVertical default hvMiddle;
  end;

procedure Register;

implementation

uses
  System.SysUtils;

procedure Register;
begin
  RegisterClass(THeaderPageControl);
end;

{ THeaderPageControl }

constructor THeaderPageControl.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FHeaderImage := TPicture.Create;
  FHeaderImage.OnChange := ImageChanged;
  FHeaderImageVisible := True;
  FHeaderImageStretch := True;
  FHeaderImageTile := False;
  FHeaderHorizontal := hhCenter;
  FHeaderVertical := hvMiddle;
  FMinHeaderHeight := TabHeight; // capture the auto height before we override it
  FHeaderHeight := 0;
end;

destructor THeaderPageControl.Destroy;
begin
  FHeaderImage.Free;
  inherited Destroy;
end;

procedure THeaderPageControl.Loaded;
begin
  inherited Loaded;
  if FHeaderHeight <= 0 then
    SetHeaderHeight(FMinHeaderHeight)
  else
    SetHeaderHeight(FHeaderHeight);
end;

procedure THeaderPageControl.SetHeaderImage(Value: TPicture);
begin
  FHeaderImage.Assign(Value);
  Invalidate;
end;

procedure THeaderPageControl.SetHeaderHeight(Value: Integer);
begin
  // Never shrink below the natural tab height (the tabs would collapse or clip).
  if Value <= 0 then
    Value := FMinHeaderHeight;
  if Value < FMinHeaderHeight then
    Value := FMinHeaderHeight;

  if (Value <> FHeaderHeight) or (Value <> TabHeight) then
  begin
    FHeaderHeight := Value;
    TabHeight := Value;
    Invalidate;
  end;
end;

procedure THeaderPageControl.ImageChanged(Sender: TObject);
begin
  Invalidate;
end;

function THeaderPageControl.ActiveTabStripHeight: Integer;
begin
  Result := TabHeight;
  if Result <= 0 then
    Result := FMinHeaderHeight;
end;

function THeaderPageControl.StripRect: TRect;
begin
  Result := Rect(0, 0, ClientWidth, ActiveTabStripHeight);
end;

function THeaderPageControl.StretchSource(const ARect: TRect; const AImg: TBitmap): TRect;
var
  SW, SH, W, H: Integer;
begin
  SW := ClientWidth;
  SH := ActiveTabStripHeight;
  W := AImg.Width;
  H := AImg.Height;
  if (SW <= 0) or (SH <= 0) or (W <= 0) or (H <= 0) then
    Result := Rect(0, 0, 0, 0)
  else
    Result := Rect(
      (ARect.Left * W) div SW,
      (ARect.Top * H) div SH,
      (ARect.Right * W) div SW,
      (ARect.Bottom * H) div SH);
end;

function THeaderPageControl.AlignedDest(const AWidth, AHeight: Integer): TRect;
var
  R: TRect;
  X, Y: Integer;
begin
  R := StripRect;
  X := R.Left;
  Y := R.Top;
  case FHeaderHorizontal of
    hhLeft:   X := R.Left;
    hhCenter: X := R.Left + (R.Width - AWidth) div 2;
    hhRight:  X := R.Right - AWidth;
  end;
  case FHeaderVertical of
    hvTop:    Y := R.Top;
    hvMiddle: Y := R.Top + (R.Height - AHeight) div 2;
    hvBottom: Y := R.Bottom - AHeight;
  end;
  Result := Rect(X, Y, X + AWidth, Y + AHeight);
end;

procedure THeaderPageControl.DrawStripImage(const ARect: TRect);
var
  Img: TBitmap;
  Dst, Clip, Src: TRect;
begin
  if FHeaderImage.Graphic = nil then
    Exit;

  Img := FHeaderImage.Bitmap;
  if Img.Empty then
    Exit;

  if FHeaderImageStretch then
  begin
    Src := StretchSource(ARect, Img);
    if (Src.Right > Src.Left) and (Src.Bottom > Src.Top) then
      Canvas.CopyRect(ARect, Img.Canvas, Src);
  end
  else if FHeaderImageTile then
  begin
    Canvas.Brush.Bitmap := Img;
    try
      Canvas.FillRect(ARect);
    finally
      Canvas.Brush.Bitmap := nil;
    end;
  end
  else
  begin
    // Natural size, positioned by alignment. Only paint the part that falls
    // inside this tab's rect so tabs tile a single continuous image.
    Dst := AlignedDest(Img.Width, Img.Height);
    if IntersectRect(Clip, ARect, Dst) then
    begin
      Src := Rect(
        Clip.Left - Dst.Left,
        Clip.Top - Dst.Top,
        Clip.Right - Dst.Left,
        Clip.Bottom - Dst.Top);
      Canvas.CopyRect(Clip, Img.Canvas, Src);
    end;
  end;
end;

procedure THeaderPageControl.DrawTabContent(const ARect: TRect; AIndex: Integer; ASelected: Boolean);
var
  R: TRect;
  Txt: string;
  SaveFontStyle: TFontStyles;
begin
  SaveFontStyle := Canvas.Font.Style;
  try
    Canvas.Font := Font;
    Canvas.Font.Style := [];
    if ASelected then
      Canvas.Font.Style := Canvas.Font.Style + [fsBold];

    Canvas.Brush.Style := bsClear;

    if not ASelected then
      Canvas.Font.Color := Font.Color;

    R := ARect;

    // Optional tab icon, drawn before the caption.
    if (Images <> nil) and (AIndex >= 0) and (AIndex < PageCount) then
    begin
      if (Pages[AIndex].ImageIndex >= 0) and
         (Pages[AIndex].ImageIndex < Images.Count) then
      begin
        Images.Draw(Canvas,
          R.Left + 6,
          (R.Top + R.Bottom - Images.Height) div 2,
          Pages[AIndex].ImageIndex);
        Inc(R.Left, Images.Width + 4);
      end;
    end;

    if (AIndex >= 0) and (AIndex < Tabs.Count) then
      Txt := Tabs[AIndex]
    else
      Txt := '';

    if Txt <> '' then
    begin
      R := Rect(Max(R.Left + 8, 0), R.Top, R.Right - 8, R.Bottom);
      DrawText(Canvas.Handle, PChar(Txt), Length(Txt), R,
        DT_CENTER or DT_VCENTER or DT_SINGLELINE or DT_END_ELLIPSIS);
    end;

    // A thin accent underline marks the active tab.
    if ASelected then
    begin
      Canvas.Brush.Style := bsSolid;
      Canvas.Brush.Color := clHighlight;
      Canvas.FillRect(Rect(ARect.Left + 2, ARect.Bottom - 3, ARect.Right - 2, ARect.Bottom - 1));
    end;
  finally
    Canvas.Brush.Style := bsSolid;
    Canvas.Font.Style := SaveFontStyle;
  end;
end;

procedure THeaderPageControl.DrawTab(AIndex: Integer; const ARect: TRect; ASelected: Boolean);
begin
  if not FHeaderImageVisible or (FHeaderImage.Graphic = nil) then
  begin
    inherited DrawTab(AIndex, ARect, ASelected);
    Exit;
  end;

  DrawStripImage(ARect);
  DrawTabContent(ARect, AIndex, ASelected);
end;

initialization
  // Register explicitly so DFM streaming can resolve the class at runtime and
  // design time. Some toolchains do not auto-call the Register procedure.
  RegisterClass(THeaderPageControl);

end.
