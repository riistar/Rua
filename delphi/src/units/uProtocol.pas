unit uProtocol;
{
  Nexon SDK named pipe protocol.
  Frame: [4-byte int32LE length][UTF-8 JSON body]
}

interface

uses
  Winapi.Windows, System.SysUtils, System.JSON;

type
  TRequestType = (
    rtUnknown,
    rtGetProductTicket,
    rtGetSDKConfiguration,
    rtProductActive,
    rtProductClosed,
    rtGetClientToken
  );

  TNexonRequest = record
    ReqType:   TRequestType;
    TypeStr:   string;
    ProductId: Integer;
    ReqId:     string;
    Version:   string;
  end;

function ReadPipeFrame(Pipe: THandle; out Data: TBytes): Boolean;
function WritePipeFrame(Pipe: THandle; const Data: TBytes): Boolean;
function ParseRequest(const Data: TBytes): TNexonRequest;
function BuildTicketResponse(const Req: TNexonRequest; const Ticket: string): TBytes;
function BuildSDKConfigResponse(const Req: TNexonRequest; const HashedUserNo: string): TBytes;
function BuildAckResponse(const Req: TNexonRequest): TBytes;
function BuildErrorResponse(const Req: TNexonRequest; Code: Integer): TBytes;

implementation

function ReadPipeFrame(Pipe: THandle; out Data: TBytes): Boolean;
var
  Len:       Integer;
  BytesRead: DWORD;
begin
  Result := False;
  Data   := nil;
  if not ReadFile(Pipe, Len, SizeOf(Len), BytesRead, nil) then Exit;
  if BytesRead <> SizeOf(Len) then Exit;
  if Len <= 0 then Exit;
  SetLength(Data, Len);
  if not ReadFile(Pipe, Data[0], Len, BytesRead, nil) then Exit;
  Result := BytesRead = DWORD(Len);
end;

function WritePipeFrame(Pipe: THandle; const Data: TBytes): Boolean;
var
  Len:     Integer;
  Written: DWORD;
begin
  Result := False;
  Len := Length(Data);
  if not WriteFile(Pipe, Len, SizeOf(Len), Written, nil) then Exit;
  if Written <> SizeOf(Len) then Exit;
  if Len = 0 then begin Result := True; Exit; end;
  Result := WriteFile(Pipe, Data[0], Len, Written, nil) and (Written = DWORD(Len));
end;

function ParseRequest(const Data: TBytes): TNexonRequest;
var
  J:       TJSONObject;
  TypeStr: string;
  Req:     TJSONObject;
begin
  Result.ReqType   := rtUnknown;
  Result.TypeStr   := '';
  Result.ProductId := 0;
  Result.ReqId     := '';
  Result.Version   := '';

  J := TJSONObject.ParseJSONValue(TEncoding.UTF8.GetString(Data)) as TJSONObject;
  if J = nil then Exit;
  try
    TypeStr        := J.GetValue<string>('type', '');
    Result.TypeStr := TypeStr;

    if      TypeStr = 'getProductTicket'    then Result.ReqType := rtGetProductTicket
    else if TypeStr = 'getSDKConfiguration' then Result.ReqType := rtGetSDKConfiguration
    else if TypeStr = 'productActive'       then Result.ReqType := rtProductActive
    else if TypeStr = 'productClosed'       then Result.ReqType := rtProductClosed
    else if TypeStr = 'getClientToken'      then Result.ReqType := rtGetClientToken;

    Result.ReqId   := J.GetValue<string>('id',  '');
    Result.Version := J.GetValue<string>('ver', '');

    Req := J.GetValue('req') as TJSONObject;
    if Req <> nil then
      Result.ProductId := Req.GetValue<Integer>('productId', 0);
  finally
    J.Free;
  end;
end;

function EncodeJSON(Obj: TJSONObject): TBytes;
begin
  Result := TEncoding.UTF8.GetBytes(Obj.ToJSON);
  Obj.Free;
end;

function BuildTicketResponse(const Req: TNexonRequest; const Ticket: string): TBytes;
var
  J, Res: TJSONObject;
begin
  J   := TJSONObject.Create;
  Res := TJSONObject.Create;
  J.AddPair('code',    TJSONNumber.Create(0));
  J.AddPair('reqType', Req.TypeStr);
  if Req.ReqId <> '' then J.AddPair('id', Req.ReqId);
  Res.AddPair('productId', TJSONNumber.Create(Req.ProductId));
  Res.AddPair('ticket', Ticket);
  J.AddPair('res', Res);
  Result := EncodeJSON(J);
end;

function BuildSDKConfigResponse(const Req: TNexonRequest; const HashedUserNo: string): TBytes;
var
  J, Res: TJSONObject;
begin
  J   := TJSONObject.Create;
  Res := TJSONObject.Create;
  J.AddPair('code',    TJSONNumber.Create(0));
  J.AddPair('reqType', Req.TypeStr);
  if Req.ReqId <> '' then J.AddPair('id', Req.ReqId);
  Res.AddPair('ccuServerName', 'ccu-edge.nexon.io');
  Res.AddPair('ccuServerPort', TJSONNumber.Create(8913));
  Res.AddPair('hashedUserNo',  HashedUserNo);
  Res.AddPair('productId',     TJSONNumber.Create(Req.ProductId));
  J.AddPair('res', Res);
  Result := EncodeJSON(J);
end;

function BuildAckResponse(const Req: TNexonRequest): TBytes;
var
  J: TJSONObject;
begin
  J := TJSONObject.Create;
  J.AddPair('code',    TJSONNumber.Create(0));
  J.AddPair('reqType', Req.TypeStr);
  if Req.ReqId <> '' then J.AddPair('id', Req.ReqId);
  Result := EncodeJSON(J);
end;

function BuildErrorResponse(const Req: TNexonRequest; Code: Integer): TBytes;
var
  J: TJSONObject;
begin
  J := TJSONObject.Create;
  J.AddPair('code',    TJSONNumber.Create(Code));
  J.AddPair('reqType', Req.TypeStr);
  if Req.ReqId <> '' then J.AddPair('id', Req.ReqId);
  Result := EncodeJSON(J);
end;

end.
