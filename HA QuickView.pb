; ==============================================================================
; Home Assistant Integration für PureBasic (GUI Version)
; Autor: Antigravity (Advanced Agentic Coding AI)
; OS: Mac / Windows / Linux (V6.30+)
; ==============================================================================

EnableExplicit

; --- Enumerationen ---
Enumeration
  #Win_Main
  #Web_Main
  #Win_Settings
  #Web_Settings
  #Win_Config
  #Txt_ConfigHeader
  #Txt_ConfigInfo
  #Frm_ConfigConnection
  #Txt_ConfigBase
  #Str_ConfigBase
  #Txt_ConfigToken
  #Str_ConfigToken
  #Btn_ConfigSave
  #Btn_ConfigCancel
  #Font_Header
  #Font_MDI
  #Event_RefreshUI = #PB_Event_FirstCustomValue
  #Event_ShowSettings
  #Event_SaveSettings
  #Event_CancelSettings
  #Event_InitSettings
  #Event_AreasLoaded
  #Event_AreasLoadFailed
  #Event_ToggleEntity
  #Event_DesignLayout
  #Event_ToggleDone
  #Event_ToggleFailed
EndEnumeration

; --- Konfiguration ---
Global HA_TOKEN.s = ""
Global HA_BASE_URL.s = ""
#Demo = #False ; #True = Demo-JSON, #False = Home Assistant

Structure HA_Entity
  id.s
  name.s
  state.s
  domain.s
  device_class.s
  icon.s
  unit.s
  brightness.s
EndStructure

Structure HA_Area
  id.s
  name.s
  temp_id.s
  temp_val.s
  humid_id.s
  humid_val.s
  List all_entities.HA_Entity() ; Alle Entitäten im Bereich (ID + Friendly Name)
EndStructure

Structure AreaConfig
  area_id.s
  visible.i
  order.i
  List visible_entities.s()
EndStructure

Global NewMap AreaConfigs.AreaConfig()
Global NewList MyAreas.HA_Area()
Global CurrentSettingsAreaID.s = ""
Global NewMap SettingsButtons.s() ; Map GadgetID -> AreaID
Global GuiOpened = #False
Global TargetAreaID.s = ""
Global SettingsDataBuffer.s = ""
Global ConfigLoaded.i = #False
Global FetchMutex.i = 0
Global FetchThread.i = 0
Global IsLoading.i = #False
Global PendingRefresh.i = #False
Global LoadedAreasPayload.s = ""
Global LoadedAreasError.s = ""
Global ToggleEntityID.s = ""
Global ToggleEntityDomain.s = ""
Global ToggleEntityState.s = ""
Global DesignLayoutData.s = ""
Global ToggleMutex.i = 0
Global ToggleThread.i = 0
Global ToggleIsLoading.i = #False
Global ToggleRequestEntityID.s = ""
Global ToggleRequestDomain.s = ""
Global ToggleRequestState.s = ""
Global ToggleResultMessage.s = ""
Global NewMap I18N.s()
Global CurrentLanguage.s = "en"
Global PreferredLanguage.s = "en" ; "", "en", "de", "fr", "es" (leer = Auto-Erkennung)
Global NewMap EntityLabels.s()

; --- Deklarationen ---
Declare RefreshGUI(ForceReload = #False)
Declare ShowAreaSettings(AreaID.s)
Declare.s GetHTMLTemplate()
Declare.s GetDemoDataJSON()
Declare.s GetSettingsHTMLTemplate(AreaName.s)
Declare SaveConfig()
Declare LoadConfig()
Declare OnJS_Settings(JsonArgs.s)
Declare OnJS_Refresh(JsonArgs.s)
Declare OnJS_Ready(JsonArgs.s)
Declare OnJS_ReadySettings(JsonArgs.s)
Declare OnJS_SaveSettings(JsonArgs.s)
Declare OnJS_CancelSettings(JsonArgs.s)
Declare OnJS_ToggleEntity(JsonArgs.s)
Declare OnJS_DesignLayout(JsonArgs.s)
Declare StartAreasRefresh()
Declare.i StartToggleRequest(EntityID.s, NextState.s, Domain.s)
Declare.i LoadAreasFromPayload(Payload.s)
Declare.i LoadDemoState()
Declare.s EscapeJSString(Text.s)
Declare UpdateMainLoadingUI(Loading.i, Message.s = "")
Declare.s GetConfigFilePath()
Declare.i EnsureConnectionConfig()
Declare InitLanguage()
Declare.i LoadLanguageStrings(LanguageCode.s)
Declare.s GetLanguageJSON(LanguageCode.s)
Declare.s DetectLanguageCode()
Declare.s T(Key.s, Fallback.s = "")
Declare.s ApplyI18NPlaceholders(Text.s)

; ---

CompilerIf Not #PB_Compiler_Thread
  MessageRequester("HA QuickView", "Please enable threadsafe executable", #PB_MessageRequester_Ok)
  End
CompilerEndIf

; --- Hilfsfunktionen für JSON ---

Procedure.s GetJSONStringSafe(Value.i, Member.s = "")
  If Not Value : ProcedureReturn "" : EndIf
  If JSONType(Value) <> #PB_JSON_Object And Member <> "" : ProcedureReturn "" : EndIf
  
  Protected MemberValue.i
  If Member <> ""
    MemberValue = GetJSONMember(Value, Member)
  Else
    MemberValue = Value
  EndIf
  
  If MemberValue And JSONType(MemberValue) = #PB_JSON_String
    ProcedureReturn GetJSONString(MemberValue)
  EndIf
  ProcedureReturn ""
EndProcedure

Procedure.s DetectLanguageCode()
  Protected Lang.s = ""
  
  Lang = LCase(Trim(GetEnvironmentVariable("LC_ALL")))
  If Lang = ""
    Lang = LCase(Trim(GetEnvironmentVariable("LC_MESSAGES")))
  EndIf
  If Lang = ""
    Lang = LCase(Trim(GetEnvironmentVariable("LANG")))
  EndIf
  If Lang = ""
    Lang = LCase(Trim(GetEnvironmentVariable("LANGUAGE")))
  EndIf
  
  If Left(Lang, 2) = "de" : ProcedureReturn "de" : EndIf
  If Left(Lang, 2) = "fr" : ProcedureReturn "fr" : EndIf
  If Left(Lang, 2) = "es" : ProcedureReturn "es" : EndIf
  If Left(Lang, 2) = "en" : ProcedureReturn "en" : EndIf
  
  ; LANGUAGE kann z. B. "fr:de:en" enthalten
  If FindString(Lang, "de", 1) : ProcedureReturn "de" : EndIf
  If FindString(Lang, "fr", 1) : ProcedureReturn "fr" : EndIf
  If FindString(Lang, "es", 1) : ProcedureReturn "es" : EndIf
  If FindString(Lang, "en", 1) : ProcedureReturn "en" : EndIf
  
  ProcedureReturn "en"
EndProcedure

Procedure.s T(Key.s, Fallback.s = "")
  If Key <> "" And FindMapElement(I18N(), Key)
    ProcedureReturn I18N()
  EndIf
  If Fallback <> ""
    ProcedureReturn Fallback
  EndIf
  ProcedureReturn Key
EndProcedure

Procedure.s ApplyI18NPlaceholders(Text.s)
  If Text = ""
    ProcedureReturn ""
  EndIf
  
  ForEach I18N()
    Text = ReplaceString(Text, "{{" + MapKey(I18N()) + "}}", I18N())
  Next
  
  ProcedureReturn Text
EndProcedure

Procedure.i LoadLanguageStrings(LanguageCode.s)
  Protected JsonPayload.s = GetLanguageJSON(LanguageCode)
  Protected Json.i
  Protected Root.i
  Protected NewMap TempLang.s()
  
  If JsonPayload = ""
    ProcedureReturn #False
  EndIf
  
  Json = ParseJSON(#PB_Any, JsonPayload)
  If Not Json
    ProcedureReturn #False
  EndIf
  
  Root = JSONValue(Json)
  If Not Root Or JSONType(Root) <> #PB_JSON_Object
    FreeJSON(Json)
    ProcedureReturn #False
  EndIf
  
  ExtractJSONMap(Root, TempLang())
  ClearMap(I18N())
  ForEach TempLang()
    I18N(MapKey(TempLang())) = TempLang()
  Next
  
  FreeJSON(Json)
  CurrentLanguage = LanguageCode
  ProcedureReturn #True
EndProcedure

Procedure InitLanguage()
  Protected Lang.s = DetectLanguageCode()
  
  If PreferredLanguage <> ""
    Lang = LCase(PreferredLanguage)
  EndIf
  
  If Not LoadLanguageStrings(Lang)
    If Not LoadLanguageStrings("en")
      ClearMap(I18N())
    EndIf
  EndIf
EndProcedure

; --- Hilfsfunktionen für HTTP ---

Procedure.s HA_SendRequest(Method.s, Endpoint.s, Payload.s = "")
  Protected NewMap Headers.s()
  Protected HttpRequest.i
  Protected Response.s = ""
  Protected Progress.i
  Protected StartMs.q
  Protected TimeoutMs.i = 15000
  
  Headers("Authorization") = "Bearer " + HA_TOKEN
  Headers("Content-Type") = "application/json"
  
  If Method = "POST"
    HttpRequest = HTTPRequest(#PB_HTTP_Post, HA_BASE_URL + Endpoint, Payload, 0, Headers())
  Else
    HttpRequest = HTTPRequest(#PB_HTTP_Get, HA_BASE_URL + Endpoint, Payload, 0, Headers())
  EndIf
  
  If HttpRequest
    StartMs = ElapsedMilliseconds()
    Repeat
      ; Wait for request to complete (WindowEvent is forbidden in bound callbacks on Mac)
      Progress = HTTPProgress(HttpRequest)
      If ElapsedMilliseconds() - StartMs > TimeoutMs
        Progress = #PB_HTTP_Failed
      EndIf
      Delay(1)
    Until Progress = #PB_HTTP_Success Or Progress = #PB_HTTP_Failed
    
    If Progress = #PB_HTTP_Success
      Response = HTTPInfo(HttpRequest, #PB_HTTP_Response)
      FinishHTTP(HttpRequest)
      ProcedureReturn Response
    Else
      ; Debug "HTTP Request fehlgeschlagen: " + Endpoint
      FinishHTTP(HttpRequest)
      ProcedureReturn ""
    EndIf
  Else
    ; Debug "Konnte HTTP Request nicht initialisieren."
    ProcedureReturn ""
  EndIf
EndProcedure

; --- API Funktionen ---

Procedure.i HA_ListAreas(List OutputList.HA_Area())
  ; Wir holen uns Bereiche und Entitäten in zwei getrennten, einfachen Schritten.
  ; Das ist viel robuster als komplexe Jinja2-Filter.
  
  ; Debug "HA_ListAreas: Hole Bereiche..."
  Protected AreasResp.s = HA_SendRequest("GET", "/api/states", "") ; Wir holen einfach alle Zustände
  If AreasResp = "" : Debug "HA Fehlgeschlagen." : ProcedureReturn #False : EndIf
  
  Protected Json = ParseJSON(#PB_Any, AreasResp)
  If Not Json : Debug "JSON Fehler" : ProcedureReturn #False : EndIf
  
  ClearList(OutputList())
  NewMap AreaMap.i()
  NewMap AreaTempEntityByArea.s()
  NewMap AreaHumidEntityByArea.s()
  
  ; 1. Bereiche identifizieren (mit sauberem Jinja-JSON-Export)
  ; Wir bauen die Liste in Jinja2 und geben sie am Ende als JSON aus.
  Protected Template.s = ~"{\"template\": \"[" +
                         ~"  {% for a in areas() %}" +
                         ~"    {" +
                         ~"      \\\"id\\\": \\\"{{ a }}\\\"," +
                         ~"      \\\"name\\\": \\\"{{ area_name(a) }}\\\"," +
                         ~"      \\\"entities\\\": {{ (area_entities(a) + (area_devices(a) | map('device_entities') | sum(start=[]))) | unique | list | to_json }}" +
                         ~"    }{% if not loop.last %},{% endif %}" +
                         ~"  {% endfor %}" +
                         ~"]\"}"
  
  Protected Response.s = HA_SendRequest("POST", "/api/template", Template)
  If Response <> ""
    Protected Json2 = ParseJSON(#PB_Any, Response)
    If Json2
      Protected Root = JSONValue(Json2)
      If JSONType(Root) = #PB_JSON_Array
        Protected i, count = JSONArraySize(Root)
        For i = 0 To count - 1
          Protected item = GetJSONElement(Root, i)
          AddElement(OutputList())
          OutputList()\id   = GetJSONStringSafe(item, "id")
          OutputList()\name = GetJSONStringSafe(item, "name")
          
          Protected ents = GetJSONMember(item, "entities")
          If ents And JSONType(ents) = #PB_JSON_Array
            Protected j, ecount = JSONArraySize(ents)
            For j = 0 To ecount - 1
              Protected eElem = GetJSONElement(ents, j)
              Protected eid.s = ""
              If eElem And JSONType(eElem) = #PB_JSON_String
                eid = GetJSONString(eElem)
              EndIf
              If eid <> "" And Left(eid, 11) <> "automation."
                AddElement(OutputList()\all_entities())
                OutputList()\all_entities()\id = eid
                OutputList()\all_entities()\name = eid
              EndIf
            Next
          EndIf
        Next
      EndIf
      FreeJSON(Json2)
    EndIf
  EndIf
  
  ; 1b. Bereichs-Registry auslesen: explizit zugewiesene Temp-/Feuchtesensoren
  ; (Home Assistant "Zugehörige Sensoren")
  Protected AreaRegResp.s = HA_SendRequest("GET", "/api/config/area_registry", "")
  If AreaRegResp <> ""
    Protected JsonAreaReg.i = ParseJSON(#PB_Any, AreaRegResp)
    If JsonAreaReg
      Protected AreaRoot.i = JSONValue(JsonAreaReg)
      If AreaRoot And JSONType(AreaRoot) = #PB_JSON_Array
        Protected ar_i.i, ar_count.i = JSONArraySize(AreaRoot)
        Protected ar_item.i, areaKey.s, tEnt.s, hEnt.s
        For ar_i = 0 To ar_count - 1
          ar_item = GetJSONElement(AreaRoot, ar_i)
          If ar_item And JSONType(ar_item) = #PB_JSON_Object
            areaKey = GetJSONStringSafe(ar_item, "area_id")
            If areaKey = ""
              areaKey = GetJSONStringSafe(ar_item, "id")
            EndIf
            If areaKey <> ""
              tEnt = GetJSONStringSafe(ar_item, "temperature_entity_id")
              hEnt = GetJSONStringSafe(ar_item, "humidity_entity_id")
              If tEnt <> ""
                AreaTempEntityByArea(areaKey) = tEnt
              EndIf
              If hEnt <> ""
                AreaHumidEntityByArea(areaKey) = hEnt
              EndIf
            EndIf
          EndIf
        Next
      EndIf
      FreeJSON(JsonAreaReg)
    EndIf
  EndIf
  
  ; 2. Namen und Sensoren sicher auflösen
  Protected RootVal = JSONValue(Json)
  NewMap StateByEntity.s()
  NewMap ClassByEntity.s()
  NewMap IconByEntity.s()
  NewMap NameByEntity.s()
  NewMap UnitByEntity.s()
  NewMap BrightnessByEntity.s()
  Protected bestTempScore.i
  Protected bestHumidScore.i
  Protected score.i
  Protected lname.s
  Protected ldomain.s
  Protected lunit.s
  Protected lclass.s
  
  If RootVal And JSONType(RootVal) = #PB_JSON_Array
    Protected s, scount = JSONArraySize(RootVal)
    For s = 0 To scount - 1
      Protected stateCheck = GetJSONElement(RootVal, s)
      If Not stateCheck Or JSONType(stateCheck) <> #PB_JSON_Object : Continue : EndIf
      
      Protected id.s = GetJSONStringSafe(stateCheck, "entity_id")
      Protected val.s = GetJSONStringSafe(stateCheck, "state")
      Protected attr = GetJSONMember(stateCheck, "attributes")
      
      Protected nm.s = id
      Protected cl.s = ""
      Protected ic.s = ""
      Protected unit.s = ""
      Protected bright.s = ""
      If attr And JSONType(attr) = #PB_JSON_Object
        nm = GetJSONStringSafe(attr, "friendly_name")
        cl = GetJSONStringSafe(attr, "device_class")
        ic = GetJSONStringSafe(attr, "icon")
        unit = GetJSONStringSafe(attr, "unit_of_measurement")
        bright = GetJSONStringSafe(attr, "brightness_pct")
        If bright = ""
          Protected brightRaw.s = GetJSONStringSafe(attr, "brightness")
          If brightRaw <> ""
            Protected b.f = ValF(brightRaw)
            If b > 0
              bright = Str(Int((b / 255.0) * 100.0 + 0.5))
            EndIf
          EndIf
        EndIf
      EndIf
      If nm = "" : nm = id : EndIf
      If id <> ""
        StateByEntity(id) = val
        ClassByEntity(id) = cl
        IconByEntity(id) = ic
        NameByEntity(id) = nm
        UnitByEntity(id) = unit
        BrightnessByEntity(id) = bright
      EndIf
    Next
  EndIf
  
  ForEach OutputList()
    OutputList()\temp_id = ""
    OutputList()\temp_val = ""
    OutputList()\humid_id = ""
    OutputList()\humid_val = ""
    
    bestTempScore = -100000
    bestHumidScore = -100000
    
    ForEach OutputList()\all_entities()
      id = OutputList()\all_entities()\id
      If id = "" : Continue : EndIf
      OutputList()\all_entities()\state = ""
      OutputList()\all_entities()\device_class = ""
      OutputList()\all_entities()\icon = ""
      OutputList()\all_entities()\unit = ""
      OutputList()\all_entities()\brightness = ""
      OutputList()\all_entities()\domain = StringField(id, 1, ".")
      
      If FindMapElement(NameByEntity(), id)
        OutputList()\all_entities()\name = NameByEntity()
      EndIf
      If FindMapElement(StateByEntity(), id)
        OutputList()\all_entities()\state = StateByEntity()
      EndIf
      If FindMapElement(IconByEntity(), id)
        OutputList()\all_entities()\icon = IconByEntity()
      EndIf
      If FindMapElement(UnitByEntity(), id)
        OutputList()\all_entities()\unit = UnitByEntity()
      EndIf
      If FindMapElement(BrightnessByEntity(), id)
        OutputList()\all_entities()\brightness = BrightnessByEntity()
      EndIf
      
      If FindMapElement(ClassByEntity(), id)
        cl = ClassByEntity()
        OutputList()\all_entities()\device_class = cl
      EndIf
      
      lclass = LCase(OutputList()\all_entities()\device_class)
      lname = LCase(OutputList()\all_entities()\name)
      ldomain = LCase(OutputList()\all_entities()\domain)
      lunit = LCase(OutputList()\all_entities()\unit)
      
      If lclass = "temperature"
        score = 0
        If ldomain = "sensor" : score + 40 : EndIf
        If FindString(lunit, "°c", 1) Or FindString(lunit, " c", 1) : score + 20 : EndIf
        If FindString(lname, "temp", 1) Or FindString(lname, "temperatur", 1) : score + 10 : EndIf
        If FindString(lname, "soll", 1) Or FindString(lname, "target", 1) Or FindString(lname, "setpoint", 1)
          score - 30
        EndIf
        If ldomain = "number" Or ldomain = "input_number" Or ldomain = "climate"
          score - 20
        EndIf
        If score > bestTempScore
          bestTempScore = score
          OutputList()\temp_id = id
          OutputList()\temp_val = OutputList()\all_entities()\state
        EndIf
      ElseIf lclass = "humidity"
        score = 0
        If ldomain = "sensor" : score + 40 : EndIf
        If FindString(lunit, "%", 1) : score + 20 : EndIf
        If FindString(lname, "humid", 1) Or FindString(lname, "feuchte", 1)
          score + 10
        EndIf
        If FindString(lname, "soll", 1) Or FindString(lname, "target", 1) Or FindString(lname, "setpoint", 1)
          score - 30
        EndIf
        If ldomain = "number" Or ldomain = "input_number" Or ldomain = "climate"
          score - 20
        EndIf
        If score > bestHumidScore
          bestHumidScore = score
          OutputList()\humid_id = id
          OutputList()\humid_val = OutputList()\all_entities()\state
        EndIf
      EndIf
    Next
    
    ; Explizite Bereichssensoren aus HA-Registry haben Priorität vor Heuristik
    If FindMapElement(AreaTempEntityByArea(), OutputList()\id)
      id = AreaTempEntityByArea()
      If id <> ""
        OutputList()\temp_id = id
        If FindMapElement(StateByEntity(), id)
          OutputList()\temp_val = StateByEntity()
        EndIf
      EndIf
    EndIf
    If FindMapElement(AreaHumidEntityByArea(), OutputList()\id)
      id = AreaHumidEntityByArea()
      If id <> ""
        OutputList()\humid_id = id
        If FindMapElement(StateByEntity(), id)
          OutputList()\humid_val = StateByEntity()
        EndIf
      EndIf
    EndIf
  Next
  FreeJSON(Json)
  
  ; Debug "HA_ListAreas: Fertig. " + Str(ListSize(OutputList())) + " Bereiche."
  ProcedureReturn #True
EndProcedure

Procedure.i AreasLoaderThread(*Unused)
  Protected NewList TempAreas.HA_Area()
  Protected Ok.i = HA_ListAreas(TempAreas())
  Protected Payload.s = ""
  Protected Json.i
  Protected StartPending.i = #False
  
  If Ok
    Json = CreateJSON(#PB_Any)
    If Json
      SetJSONObject(JSONValue(Json))
      InsertJSONList(AddJSONMember(JSONValue(Json), "areas"), TempAreas())
      Payload = ComposeJSON(Json)
      FreeJSON(Json)
    Else
      Ok = #False
    EndIf
  EndIf
  
  LockMutex(FetchMutex)
  IsLoading = #False
  LoadedAreasPayload = Payload
  If Ok
    LoadedAreasError = ""
  Else
    LoadedAreasError = T("MSG_LOAD_AREAS_FAILED", "Loading areas failed.")
  EndIf
  StartPending = PendingRefresh
  PendingRefresh = #False
  UnlockMutex(FetchMutex)
  
  If Ok
    PostEvent(#Event_AreasLoaded)
  Else
    PostEvent(#Event_AreasLoadFailed)
  EndIf
  
  If StartPending
    StartAreasRefresh()
  EndIf
  
  ProcedureReturn 0
EndProcedure

Procedure StartAreasRefresh()
  Protected StartThread.i = #False
  
  LockMutex(FetchMutex)
  If IsLoading
    PendingRefresh = #True
  Else
    IsLoading = #True
    LoadedAreasPayload = ""
    LoadedAreasError = ""
    StartThread = #True
  EndIf
  UnlockMutex(FetchMutex)
  
  If StartThread
    UpdateMainLoadingUI(#True, T("MSG_UPDATING", "Updating..."))
    FetchThread = CreateThread(@AreasLoaderThread(), 0)
    If FetchThread = 0
      LockMutex(FetchMutex)
      IsLoading = #False
      LoadedAreasError = T("MSG_THREAD_START_FAILED", "Thread could not be started.")
      UnlockMutex(FetchMutex)
      UpdateMainLoadingUI(#False, T("MSG_THREAD_START_FAILED", "Thread could not be started."))
      PostEvent(#Event_AreasLoadFailed)
    EndIf
  EndIf
EndProcedure

Procedure.i ToggleEntityThread(*Unused)
  Protected EntityID.s, ToggleDomain.s, NextState.s
  Protected ToggleService.s, TogglePayload.s, ToggleResp.s
  Protected Json.i
  
  LockMutex(ToggleMutex)
  EntityID = ToggleRequestEntityID
  ToggleDomain = ToggleRequestDomain
  NextState = ToggleRequestState
  UnlockMutex(ToggleMutex)
  
  ToggleService = "/api/services/" + ToggleDomain + "/turn_" + NextState
  
  Json = CreateJSON(#PB_Any)
  If Json
    SetJSONObject(JSONValue(Json))
    SetJSONString(AddJSONMember(JSONValue(Json), "entity_id"), EntityID)
    TogglePayload = ComposeJSON(Json)
    FreeJSON(Json)
    ToggleResp = HA_SendRequest("POST", ToggleService, TogglePayload)
  EndIf
  
  LockMutex(ToggleMutex)
  ToggleIsLoading = #False
  If ToggleResp = ""
    ToggleResultMessage = T("MSG_TOGGLE_FAILED", "Switching failed.")
  Else
    ToggleResultMessage = ""
  EndIf
  UnlockMutex(ToggleMutex)
  
  If ToggleResp = ""
    PostEvent(#Event_ToggleFailed)
  Else
    PostEvent(#Event_ToggleDone)
  EndIf
  
  ProcedureReturn 0
EndProcedure

Procedure.i StartToggleRequest(EntityID.s, NextState.s, Domain.s)
  Protected CanStart.i = #False
  
  If EntityID = "" Or NextState = "" Or Domain = ""
    ProcedureReturn #False
  EndIf
  
  LockMutex(ToggleMutex)
  If Not ToggleIsLoading
    ToggleIsLoading = #True
    ToggleRequestEntityID = EntityID
    ToggleRequestState = NextState
    ToggleRequestDomain = Domain
    ToggleResultMessage = ""
    CanStart = #True
  EndIf
  UnlockMutex(ToggleMutex)
  
  If Not CanStart
    ProcedureReturn #False
  EndIf
  
  UpdateMainLoadingUI(#True, T("MSG_TOGGLING", "Switching..."))
  ToggleThread = CreateThread(@ToggleEntityThread(), 0)
  If ToggleThread = 0
    LockMutex(ToggleMutex)
    ToggleIsLoading = #False
    ToggleResultMessage = T("MSG_THREAD_START_FAILED", "Thread could not be started.")
    UnlockMutex(ToggleMutex)
    PostEvent(#Event_ToggleFailed)
    ProcedureReturn #False
  EndIf
  
  ProcedureReturn #True
EndProcedure

Procedure.i LoadAreasFromPayload(Payload.s)
  Protected Json.i
  Protected Root.i
  Protected jAreas.i
  
  If Payload = ""
    ProcedureReturn #False
  EndIf
  
  Json = ParseJSON(#PB_Any, Payload)
  If Not Json
    ProcedureReturn #False
  EndIf
  
  Root = JSONValue(Json)
  jAreas = GetJSONMember(Root, "areas")
  If Not jAreas Or JSONType(jAreas) <> #PB_JSON_Array
    FreeJSON(Json)
    ProcedureReturn #False
  EndIf
  
  ClearList(MyAreas())
  ExtractJSONList(jAreas, MyAreas())
  FreeJSON(Json)
  ProcedureReturn #True
EndProcedure

Procedure.i LoadDemoState()
  Protected Payload.s, Json.i, Root.i, jAreas.i, jConfigs.i
  
  If Not #Demo
    ProcedureReturn #False
  EndIf
  
  Payload = GetDemoDataJSON()
  If Payload = ""
    ProcedureReturn #False
  EndIf
  
  Json = ParseJSON(#PB_Any, Payload)
  If Not Json
    ProcedureReturn #False
  EndIf
  
  Root = JSONValue(Json)
  jAreas = GetJSONMember(Root, "areas")
  If Not jAreas Or JSONType(jAreas) <> #PB_JSON_Array
    FreeJSON(Json)
    ProcedureReturn #False
  EndIf
  
  ClearList(MyAreas())
  ExtractJSONList(jAreas, MyAreas())
  
  ; Default-Configs aus Demo nur übernehmen, wenn noch keine (Demo-)Config geladen ist.
  If MapSize(AreaConfigs()) = 0
    jConfigs = GetJSONMember(Root, "configs")
    If jConfigs And JSONType(jConfigs) = #PB_JSON_Object
      ExtractJSONMap(jConfigs, AreaConfigs())
    EndIf
  EndIf
  
  FreeJSON(Json)
  ProcedureReturn #True
EndProcedure

Procedure.s GetMDIChar(High.w, Low.w)
  Protected Result.s = "  "
  PokeW(@Result, High)
  PokeW(@Result + 2, Low)
  ProcedureReturn Result
EndProcedure

Procedure.s EscapeXML(Text.s)
  Text = ReplaceString(Text, "&", "&amp;")
  Text = ReplaceString(Text, "<", "&lt;")
  Text = ReplaceString(Text, ">", "&gt;")
  Text = ReplaceString(Text, "'", "&apos;")
  Text = ReplaceString(Text, ~"\"", "&quot;")
  ProcedureReturn Text
EndProcedure

Procedure.s EscapeJSString(Text.s)
  Text = ReplaceString(Text, "\\", "\\\\")
  Text = ReplaceString(Text, "'", "\\'")
  Text = ReplaceString(Text, #CRLF$, " ")
  Text = ReplaceString(Text, #LF$, " ")
  Text = ReplaceString(Text, #CR$, " ")
  ProcedureReturn Text
EndProcedure

Procedure UpdateMainLoadingUI(Loading.i, Message.s = "")
  Protected Flag.s
  
  If Not IsGadget(#Web_Main)
    ProcedureReturn
  EndIf
  
  If Loading
    Flag = "true"
  Else
    Flag = "false"
  EndIf
  
  WebViewExecuteScript(#Web_Main, "if (window.setLoading) setLoading(" + Flag + ", '" + EscapeJSString(Message) + "')")
EndProcedure

; --- Persistence ---

Procedure.i EnsureDirectoryTree(Path.s)
  Protected Work.s = Trim(Path)
  Protected Current.s = ""
  Protected Part.s = ""
  Protected i.i, Count.i
  Protected Sep.s = #PS$
  
  If Work = ""
    ProcedureReturn #False
  EndIf
  
  Work = ReplaceString(Work, #NPS$, Sep)
  
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    ; Laufwerkspräfix (z. B. C:) erhalten
    If Len(Work) >= 2 And Mid(Work, 2, 1) = ":"
      Current = Left(Work, 2)
      Work = Mid(Work, 3)
    EndIf
  CompilerEndIf
  
  If Left(Work, 1) = Sep
    Current = Sep
    While Left(Work, 1) = Sep
      Work = Mid(Work, 2)
    Wend
  EndIf
  
  Count = CountString(Work, Sep) + 1
  For i = 1 To Count
    Part = StringField(Work, i, Sep)
    If Part = "" : Continue : EndIf
    
    If Current = "" Or Right(Current, 1) = Sep
      Current + Part
    Else
      Current + Sep + Part
    EndIf
    CreateDirectory(Current)
  Next
  
  If FileSize(Path) = -2
    ProcedureReturn #True
  EndIf
  
  ProcedureReturn #False
EndProcedure

Procedure.s GetConfigFilePath()
  Protected BaseDir.s = ""
  Protected AppDir.s = ""
  Protected EnvDir.s = ""
  
  CompilerSelect #PB_Compiler_OS
    CompilerCase #PB_OS_MacOS
      ; macOS: ~/Library/Application Support/HA QuickView/
      BaseDir = GetHomeDirectory() + "Library/Application Support/"
      
    CompilerCase #PB_OS_Windows
      ; Windows: %APPDATA%\HA QuickView\
      EnvDir = Trim(GetEnvironmentVariable("APPDATA"))
      If EnvDir = ""
        EnvDir = GetHomeDirectory() + "AppData" + #PS$ + "Roaming"
      EndIf
      If Right(EnvDir, 1) <> #PS$ And Right(EnvDir, 1) <> #NPS$
        EnvDir + #PS$
      EndIf
      BaseDir = EnvDir
      
    CompilerDefault
      ; Linux/Unix: $XDG_CONFIG_HOME/HA QuickView/ oder ~/.config/HA QuickView/
      EnvDir = Trim(GetEnvironmentVariable("XDG_CONFIG_HOME"))
      If EnvDir <> ""
        BaseDir = EnvDir
      Else
        BaseDir = GetHomeDirectory() + ".config"
      EndIf
      If Right(BaseDir, 1) <> #PS$ And Right(BaseDir, 1) <> #NPS$
        BaseDir + #PS$
      EndIf
  CompilerEndSelect
  
  BaseDir = ReplaceString(BaseDir, #NPS$, #PS$)
  AppDir = BaseDir + "HA QuickView" + #PS$
  
  ; Verzeichnisstruktur anlegen (benutzerabhängig, getrennt von der App)
  EnsureDirectoryTree(BaseDir)
  EnsureDirectoryTree(AppDir)
  
  If #Demo
    ; Demo nutzt eigene Datei, damit Live-Konfiguration unberührt bleibt
    ProcedureReturn AppDir + "config.demo.json"
  EndIf
  
  ProcedureReturn AppDir + "config.json"
EndProcedure

Procedure SaveConfig()
  Protected Json = CreateJSON(#PB_Any)
  Protected Root.i, jAreas.i, jLabels.i
  If Json
    Root = JSONValue(Json)
    SetJSONObject(Root)
    SetJSONString(AddJSONMember(Root, "ha_token"), HA_TOKEN)
    SetJSONString(AddJSONMember(Root, "ha_base_url"), HA_BASE_URL)
    jAreas = AddJSONMember(Root, "areas")
    InsertJSONMap(jAreas, AreaConfigs())
    jLabels = AddJSONMember(Root, "entity_labels")
    InsertJSONMap(jLabels, EntityLabels())
    SaveJSON(Json, GetConfigFilePath(), #PB_JSON_PrettyPrint)
    FreeJSON(Json)
  EndIf
EndProcedure

Procedure LoadConfig()
  Protected Root.i, vToken.i, vBase.i, vAreas.i, vLabels.i
  Protected Json = LoadJSON(#PB_Any, GetConfigFilePath())
  If Json
    Root = JSONValue(Json)
    If Root And JSONType(Root) = #PB_JSON_Object
      vToken = GetJSONMember(Root, "ha_token")
      If vToken And JSONType(vToken) = #PB_JSON_String
        HA_TOKEN = GetJSONString(vToken)
      EndIf
      vBase = GetJSONMember(Root, "ha_base_url")
      If vBase And JSONType(vBase) = #PB_JSON_String
        HA_BASE_URL = GetJSONString(vBase)
      EndIf
      
      vAreas = GetJSONMember(Root, "areas")
      ClearMap(AreaConfigs())
      If vAreas And JSONType(vAreas) = #PB_JSON_Object
        ExtractJSONMap(vAreas, AreaConfigs())
      Else
        ; Legacy-Format: Root selbst war die Area-Map
        ExtractJSONMap(Root, AreaConfigs())
      EndIf
      
      vLabels = GetJSONMember(Root, "entity_labels")
      ClearMap(EntityLabels())
      If vLabels And JSONType(vLabels) = #PB_JSON_Object
        ExtractJSONMap(vLabels, EntityLabels())
      EndIf
    EndIf
    FreeJSON(Json)
  EndIf
  ConfigLoaded = #True
EndProcedure

Procedure.i EnsureConnectionConfig()
  Protected Event.i, Win.i, Gad.i
  If #Demo
    ProcedureReturn #True
  EndIf
  Protected UrlVal.s, TokenVal.s
  Protected Saved.i = #False
  Protected WinW.i = 760
  Protected WinH.i = 300
  Protected Margin.i = 24
  
  If Trim(HA_BASE_URL) <> "" And Trim(HA_TOKEN) <> ""
    ProcedureReturn #True
  EndIf
  
  If OpenWindow(#Win_Config, 0, 0, WinW, WinH, T("WIN_CONFIG_TITLE", "HA QuickView - Connection Setup"), #PB_Window_SystemMenu | #PB_Window_ScreenCentered)
    TextGadget(#Txt_ConfigHeader, Margin, 16, WinW - Margin * 2, 26, T("CFG_HEADER", "Connect Home Assistant"))
    TextGadget(#Txt_ConfigInfo, Margin, 44, WinW - Margin * 2, 22, T("CFG_INFO", "Please enter URL and long-lived access token."))
    FrameGadget(#Frm_ConfigConnection, Margin - 4, 74, WinW - (Margin - 4) * 2, 166, T("CFG_GROUP", "Connection Details"))
    
    TextGadget(#Txt_ConfigBase, Margin + 12, 102, WinW - (Margin + 12) * 2, 20, T("CFG_URL_LABEL", "Home Assistant URL (e.g. http://homeassistant.local:8123)"))
    StringGadget(#Str_ConfigBase, Margin + 12, 124, WinW - (Margin + 12) * 2, 30, HA_BASE_URL)
    TextGadget(#Txt_ConfigToken, Margin + 12, 164, WinW - (Margin + 12) * 2, 20, T("CFG_TOKEN_LABEL", "Long-Lived Access Token"))
    StringGadget(#Str_ConfigToken, Margin + 12, 186, WinW - (Margin + 12) * 2, 30, HA_TOKEN)
    
    ButtonGadget(#Btn_ConfigSave, WinW - 250, WinH - 52, 110, 34, T("TXT_SAVE", "Save"), #PB_Button_Default)
    ButtonGadget(#Btn_ConfigCancel, WinW - 128, WinH - 52, 110, 34, T("TXT_CANCEL", "Cancel"))
    
    If Trim(HA_BASE_URL) = ""
      SetGadgetText(#Str_ConfigBase, "http://homeassistant.local:8123")
    EndIf
    SetActiveGadget(#Str_ConfigBase)
    
    Repeat
      Event = WaitWindowEvent()
      Win = EventWindow()
      
      If Event = #PB_Event_Gadget And Win = #Win_Config
        Gad = EventGadget()
        If Gad = #Btn_ConfigSave
          UrlVal = Trim(GetGadgetText(#Str_ConfigBase))
          TokenVal = Trim(GetGadgetText(#Str_ConfigToken))
          If Right(UrlVal, 1) = "/"
            UrlVal = Left(UrlVal, Len(UrlVal) - 1)
          EndIf
          
          If UrlVal <> "" And TokenVal <> ""
            If Left(LCase(UrlVal), 7) <> "http://" And Left(LCase(UrlVal), 8) <> "https://"
              MessageRequester(T("MSG_INVALID_URL_TITLE", "Invalid URL"), T("MSG_INVALID_URL_BODY", "Please provide the URL with http:// or https://."), #PB_MessageRequester_Warning)
              Continue
            EndIf
            HA_BASE_URL = UrlVal
            HA_TOKEN = TokenVal
            SaveConfig()
            Saved = #True
            Break
          Else
            MessageRequester(T("MSG_MISSING_FIELDS_TITLE", "Missing Information"), T("MSG_MISSING_FIELDS_BODY", "Please enter URL and access token."), #PB_MessageRequester_Warning)
          EndIf
        ElseIf Gad = #Btn_ConfigCancel
          Break
        EndIf
      ElseIf Event = #PB_Event_CloseWindow And Win = #Win_Config
        Break
      EndIf
    ForEver
    
    CloseWindow(#Win_Config)
  EndIf
  
  ProcedureReturn Saved
EndProcedure

Procedure.s GetEmbeddedTemplate(*Start, *End)
  Protected ByteLen.i = *End - *Start
  If ByteLen <= 0
    ProcedureReturn ""
  EndIf
  ProcedureReturn PeekS(*Start, ByteLen, #PB_UTF8 | #PB_ByteLength)
EndProcedure

Procedure.s GetDemoDataJSON()
  ProcedureReturn GetEmbeddedTemplate(?DemoData_Begin, ?DemoData_End)
EndProcedure

Procedure.s GetLanguageJSON(LanguageCode.s)
  Select LCase(LanguageCode)
    Case "de"
      ProcedureReturn GetEmbeddedTemplate(?LangDE_Begin, ?LangDE_End)
    Case "en"
      ProcedureReturn GetEmbeddedTemplate(?LangEN_Begin, ?LangEN_End)
    Case "fr"
      ProcedureReturn GetEmbeddedTemplate(?LangFR_Begin, ?LangFR_End)
    Case "es"
      ProcedureReturn GetEmbeddedTemplate(?LangES_Begin, ?LangES_End)
    Case "it"
      ProcedureReturn GetEmbeddedTemplate(?LangIT_Begin, ?LangIT_End)
  EndSelect
  ProcedureReturn ""
EndProcedure

Procedure.s GetHTMLTemplate()
  Protected html.s = GetEmbeddedTemplate(?MainHTML_Begin, ?MainHTML_End)
  Protected DemoFlag.s = "false"
  Protected DemoJSON.s = ""
  If #Demo
    DemoFlag = "true"
    DemoJSON = EscapeJSString(GetDemoDataJSON())
  EndIf
  html = ReplaceString(html, "{{HA_BASE_URL}}", EscapeJSString(HA_BASE_URL))
  html = ReplaceString(html, "{{HA_TOKEN}}", EscapeJSString(HA_TOKEN))
  html = ReplaceString(html, "{{DEMO_MODE}}", DemoFlag)
  html = ReplaceString(html, "{{DEMO_DATA_INLINE}}", DemoJSON)
  html = ApplyI18NPlaceholders(html)
  ProcedureReturn html
EndProcedure

Procedure.s GetSettingsHTMLTemplate(AreaName.s)
  Protected html.s = GetEmbeddedTemplate(?SettingsHTML_Begin, ?SettingsHTML_End)
  html = ReplaceString(html, "{{AREA_NAME}}", EscapeXML(AreaName))
  html = ApplyI18NPlaceholders(html)
  ProcedureReturn html
EndProcedure

DataSection
  MainHTML_Begin:
  IncludeBinary "assets/templates/main.html"
  MainHTML_End:
  SettingsHTML_Begin:
  IncludeBinary "assets/templates/settings.html"
  SettingsHTML_End:
  DemoData_Begin:
  IncludeBinary "assets/demo-data.json"
  DemoData_End:
  LangDE_Begin:
  IncludeBinary "assets/i18n/lang.de.json"
  LangDE_End:
  LangEN_Begin:
  IncludeBinary "assets/i18n/lang.en.json"
  LangEN_End:
  LangFR_Begin:
  IncludeBinary "assets/i18n/lang.fr.json"
  LangFR_End:
  LangES_Begin:
  IncludeBinary "assets/i18n/lang.es.json"
  LangES_End:
  LangIT_Begin:
  IncludeBinary "assets/i18n/lang.it.json"
  LangIT_End:
EndDataSection

; --- GUI Funktionen (Dialog Library) ---

Procedure OnJS_Settings(JsonArgs.s)
  Protected Json = ParseJSON(#PB_Any, JsonArgs)
  If Json
    Protected RootVal = JSONValue(Json)
    If RootVal And JSONType(RootVal) = #PB_JSON_Array And JSONArraySize(RootVal) > 0
      Protected Arg0Val = GetJSONElement(RootVal, 0)
      If Arg0Val And JSONType(Arg0Val) = #PB_JSON_String
        TargetAreaID = GetJSONString(Arg0Val)
      EndIf
    EndIf
    FreeJSON(Json)
  EndIf
  PostEvent(#Event_ShowSettings)
EndProcedure

Procedure OnJS_Refresh(Args.s)
  PostEvent(#Event_RefreshUI)
EndProcedure

Procedure OnJS_Ready(Args.s)
  PostEvent(#Event_RefreshUI)
EndProcedure

Procedure OnJS_ReadySettings(Args.s)
  PostEvent(#Event_InitSettings)
EndProcedure

Procedure OnJS_SaveSettings(Args.s)
  SettingsDataBuffer = Args
  PostEvent(#Event_SaveSettings)
EndProcedure

Procedure OnJS_CancelSettings(Args.s)
  ; Debug "CALLBACK: OnJS_CancelSettings"
  PostEvent(#Event_CancelSettings)
EndProcedure

Procedure OnJS_ToggleEntity(JsonArgs.s)
  Protected Json = ParseJSON(#PB_Any, JsonArgs)
  If Json
    Protected RootVal = JSONValue(Json)
    If RootVal And JSONType(RootVal) = #PB_JSON_Array And JSONArraySize(RootVal) >= 2
      Protected Arg0Val = GetJSONElement(RootVal, 0)
      Protected Arg1Val = GetJSONElement(RootVal, 1)
      Protected Arg2Val = GetJSONElement(RootVal, 2)
      
      If Arg0Val And JSONType(Arg0Val) = #PB_JSON_String
        ToggleEntityID = GetJSONString(Arg0Val)
      EndIf
      If Arg1Val And JSONType(Arg1Val) = #PB_JSON_String
        ToggleEntityState = LCase(GetJSONString(Arg1Val))
      EndIf
      If Arg2Val And JSONType(Arg2Val) = #PB_JSON_String
        ToggleEntityDomain = LCase(GetJSONString(Arg2Val))
      Else
        ToggleEntityDomain = ""
      EndIf
    EndIf
    FreeJSON(Json)
  EndIf
  PostEvent(#Event_ToggleEntity)
EndProcedure

Procedure OnJS_DesignLayout(JsonArgs.s)
  DesignLayoutData = JsonArgs
  PostEvent(#Event_DesignLayout)
EndProcedure

Procedure ShowAreaSettings(AreaID.s)
  Protected AreaName.s = ""
  Protected ParentHandle.i = 0
  
  If #Demo And ListSize(MyAreas()) = 0
    LoadDemoState()
  EndIf
  
  ForEach MyAreas()
    If MyAreas()\id = AreaID : AreaName = MyAreas()\name : Break : EndIf
  Next
  
  If IsWindow(#Win_Main)
    ParentHandle = WindowID(#Win_Main)
  EndIf
  
  CurrentSettingsAreaID = AreaID
  If Not IsWindow(#Win_Settings)
    If OpenWindow(#Win_Settings, 0, 0, 600, 700, T("WIN_SETTINGS_PREFIX", "Setup:") + " " + AreaName, #PB_Window_SystemMenu | #PB_Window_WindowCentered | #PB_Window_Invisible, ParentHandle)
      WebViewGadget(#Web_Settings, 0, 0, 600, 700)
      BindWebViewCallback(#Web_Settings, "OnJS_ReadySettings", @OnJS_ReadySettings())
      BindWebViewCallback(#Web_Settings, "OnJS_SaveSettings", @OnJS_SaveSettings())
      BindWebViewCallback(#Web_Settings, "OnJS_CancelSettings", @OnJS_CancelSettings())
      SetGadgetItemText(#Web_Settings, #PB_WebView_HtmlCode, GetSettingsHTMLTemplate(AreaName))
    EndIf
  Else
    SetWindowTitle(#Win_Settings, T("WIN_SETTINGS_PREFIX", "Setup:") + " " + AreaName)
    SetGadgetItemText(#Web_Settings, #PB_WebView_HtmlCode, GetSettingsHTMLTemplate(AreaName))
  EndIf
  
  If IsWindow(#Win_Main)
    DisableWindow(#Win_Main, #True)
  EndIf
  HideWindow(#Win_Settings, #False)
  PostEvent(#Event_InitSettings) ; Force data refresh for the new area
EndProcedure

Procedure RefreshGUI(ForceReload = #False)
  Protected LoadingNow.i
  Protected ConfigChanged.i = #False
  Protected NextOrder.i = 1
  
  ; Konfiguration nur einmal beim Start laden
  If Not ConfigLoaded
    LoadConfig()
  EndIf
  
  ; Daten im Hintergrund laden
  If #Demo
    If ListSize(MyAreas()) = 0
      LoadDemoState()
    EndIf
  Else
    If ListSize(MyAreas()) = 0 Or ForceReload
      StartAreasRefresh()
    EndIf
  EndIf
  
  ; WebView Initialisierung / Update
  If Not IsWindow(#Win_Main)
    If OpenWindow(#Win_Main, 0, 0, 1000, 700, T("WIN_MAIN_TITLE", "HA QuickView"), #PB_Window_SystemMenu | #PB_Window_ScreenCentered | #PB_Window_SizeGadget)
      WebViewGadget(#Web_Main, 0, 0, WindowWidth(#Win_Main), WindowHeight(#Win_Main))
      BindWebViewCallback(#Web_Main, "OnJS_Settings", @OnJS_Settings())
      BindWebViewCallback(#Web_Main, "OnJS_Refresh", @OnJS_Refresh())
      BindWebViewCallback(#Web_Main, "OnJS_Ready", @OnJS_Ready())
      BindWebViewCallback(#Web_Main, "OnJS_ToggleEntity", @OnJS_ToggleEntity())
      BindWebViewCallback(#Web_Main, "OnJS_DesignLayout", @OnJS_DesignLayout())
      SetGadgetItemText(#Web_Main, #PB_WebView_HtmlCode, GetHTMLTemplate())
      GuiOpened = #True
    EndIf
  EndIf
  
  LockMutex(FetchMutex)
  LoadingNow = IsLoading
  UnlockMutex(FetchMutex)
  
  If LoadingNow
    UpdateMainLoadingUI(#True, T("MSG_UPDATING", "Updating..."))
  Else
    UpdateMainLoadingUI(#False, "")
  EndIf
  
  ; Design-Defaults und Migration:
  ; alte Configs hatten visible/order nicht, deshalb visible=0/order=0 -> als "unset" behandeln.
  ForEach MyAreas()
    If FindMapElement(AreaConfigs(), MyAreas()\id)
      If AreaConfigs()\area_id = ""
        AreaConfigs()\area_id = MyAreas()\id
        ConfigChanged = #True
      EndIf
      If AreaConfigs()\order <= 0
        AreaConfigs()\order = NextOrder
        If AreaConfigs()\visible = 0
          AreaConfigs()\visible = 1
        EndIf
        ConfigChanged = #True
      ElseIf AreaConfigs()\visible <> 0 And AreaConfigs()\visible <> 1
        AreaConfigs()\visible = 1
        ConfigChanged = #True
      EndIf
    Else
      AreaConfigs(MyAreas()\id)\area_id = MyAreas()\id
      AreaConfigs(MyAreas()\id)\visible = 1
      AreaConfigs(MyAreas()\id)\order = NextOrder
      ConfigChanged = #True
    EndIf
    NextOrder + 1
  Next
  
  If ConfigChanged
    SaveConfig()
  EndIf
  
  ; Daten an WebView senden
  Protected Json = CreateJSON(#PB_Any)
  If Json
    Protected Root = JSONValue(Json)
    SetJSONObject(Root)
    
    Protected jAreas = AddJSONMember(Root, "areas")
    InsertJSONList(jAreas, MyAreas())
    
    Protected jConfigs = AddJSONMember(Root, "configs")
    InsertJSONMap(jConfigs, AreaConfigs())
    
    Protected jEntityLabels = AddJSONMember(Root, "entity_labels")
    InsertJSONMap(jEntityLabels, EntityLabels())
    
    WebViewExecuteScript(#Web_Main, "updateUI(" + ComposeJSON(Json) + ")")
    FreeJSON(Json)
  EndIf
  
EndProcedure

; --- Hauptprogramm ---

Define Event, Window, i, TargetAreaID_Local.s
Define NewList Params.s()
Define *FoundArea.HA_Area
Define Json, RootVal, Arg0Val, ArgVisibleVal, ArgLabelsVal, jAll, jEnt, jVisible, jLabels, Script.s
Define PayloadCopy.s, ErrorCopy.s
Define ToggleDomain.s
Define DesignAction.s, DesignAreaID.s, VisibleFlag.i, OrderPos.i, Arg1Val, Arg2Val
Define NewMap IncomingLabels.s()

InitLanguage()

FetchMutex = CreateMutex()
If FetchMutex = 0
  MessageRequester(T("MSG_ERROR_TITLE", "Error"), T("MSG_MUTEX_FAILED", "Mutex could not be created."), #PB_MessageRequester_Error)
  End
EndIf

ToggleMutex = CreateMutex()
If ToggleMutex = 0
  MessageRequester(T("MSG_ERROR_TITLE", "Error"), T("MSG_TOGGLE_MUTEX_FAILED", "Toggle mutex could not be created."), #PB_MessageRequester_Error)
  End
EndIf

LoadConfig()
If Not EnsureConnectionConfig()
  End
EndIf

RefreshGUI()

Repeat
  Event = WaitWindowEvent()
  If Event = 0 : Continue : EndIf
  Window = EventWindow()
  
  ; Debug "LOOP: Event=" + Str(Event) + " Window=" + Str(Window)
  
  If Event = #PB_Event_SizeWindow
    If Window = #Win_Main
      ResizeGadget(#Web_Main, 0, 0, WindowWidth(#Win_Main), WindowHeight(#Win_Main))
    ElseIf Window = #Win_Settings
      ResizeGadget(#Web_Settings, 0, 0, WindowWidth(#Win_Settings), WindowHeight(#Win_Settings))
    EndIf
    
  ElseIf Event = #Event_RefreshUI
    If #Demo
      LoadDemoState()
      RefreshGUI()
    Else
      StartAreasRefresh()
    EndIf
    
  ElseIf Event = #Event_ShowSettings
    If TargetAreaID <> ""
      TargetAreaID_Local = TargetAreaID
      TargetAreaID = ""
      ShowAreaSettings(TargetAreaID_Local)
    EndIf
    
  ElseIf Event = #Event_SaveSettings
    If CurrentSettingsAreaID <> ""
      ClearList(Params())
      ClearMap(IncomingLabels())
      Json = ParseJSON(#PB_Any, SettingsDataBuffer)
      If Json
        RootVal = JSONValue(Json)
        If RootVal And JSONType(RootVal) = #PB_JSON_Array And JSONArraySize(RootVal) > 0
          Arg0Val = GetJSONElement(RootVal, 0)
          If Arg0Val
            If JSONType(Arg0Val) = #PB_JSON_Array
              ; Legacy-Payload: direktes String-Array
              ExtractJSONList(Arg0Val, Params())
            ElseIf JSONType(Arg0Val) = #PB_JSON_Object
              ; Neues Payload: { visible: [...], labels: {...} }
              ArgVisibleVal = GetJSONMember(Arg0Val, "visible")
              If ArgVisibleVal And JSONType(ArgVisibleVal) = #PB_JSON_Array
                ExtractJSONList(ArgVisibleVal, Params())
              EndIf
              
              ArgLabelsVal = GetJSONMember(Arg0Val, "labels")
              If ArgLabelsVal And JSONType(ArgLabelsVal) = #PB_JSON_Object
                ExtractJSONMap(ArgLabelsVal, IncomingLabels())
              EndIf
            EndIf
          EndIf
        EndIf
        FreeJSON(Json)
      EndIf
      
      AreaConfigs(CurrentSettingsAreaID)\area_id = CurrentSettingsAreaID
      If AreaConfigs(CurrentSettingsAreaID)\visible <> 0 And AreaConfigs(CurrentSettingsAreaID)\visible <> 1
        AreaConfigs(CurrentSettingsAreaID)\visible = 1
      EndIf
      If AreaConfigs(CurrentSettingsAreaID)\order <= 0
        AreaConfigs(CurrentSettingsAreaID)\order = 1
      EndIf
      ClearList(AreaConfigs(CurrentSettingsAreaID)\visible_entities())
      ForEach Params()
        AddElement(AreaConfigs(CurrentSettingsAreaID)\visible_entities())
        AreaConfigs(CurrentSettingsAreaID)\visible_entities() = Params()
      Next
      
      ; Labels für Entitäten dieses Bereichs ersetzen
      *FoundArea = 0
      ForEach MyAreas()
        If MyAreas()\id = CurrentSettingsAreaID
          *FoundArea = @MyAreas()
          Break
        EndIf
      Next
      If *FoundArea
        ForEach *FoundArea\all_entities()
          DeleteMapElement(EntityLabels(), *FoundArea\all_entities()\id)
        Next
      EndIf
      ForEach IncomingLabels()
        If Trim(IncomingLabels()) <> ""
          EntityLabels(MapKey(IncomingLabels())) = IncomingLabels()
        EndIf
      Next
      
      SaveConfig()
      
      CurrentSettingsAreaID = ""
      If IsWindow(#Win_Settings)
        HideWindow(#Win_Settings, #True)
      EndIf
      If IsWindow(#Win_Main)
        DisableWindow(#Win_Main, #False)
      EndIf
      PostEvent(#Event_RefreshUI)
    EndIf
    
  ElseIf Event = #Event_CancelSettings
    ; Debug "EVENT: #Event_CancelSettings"
    CurrentSettingsAreaID = ""
    If IsWindow(#Win_Settings)
      HideWindow(#Win_Settings, #True)
    EndIf
    If IsWindow(#Win_Main)
      DisableWindow(#Win_Main, #False)
    EndIf
    
  ElseIf Event = #Event_InitSettings
    ; Debug "DEBUG: InitSettings Event verarbeitet."
    If IsWindow(#Win_Settings) And IsGadget(#Web_Settings) And CurrentSettingsAreaID <> ""
      *FoundArea = 0
      ForEach MyAreas()
        If MyAreas()\id = CurrentSettingsAreaID
          *FoundArea = @MyAreas()
          Break
        EndIf
      Next
      
      If *FoundArea
        ; Debug "DEBUG: Sende Daten für Bereich: " + *FoundArea\name
        Json = CreateJSON(#PB_Any)
        If Json
          SetJSONObject(JSONValue(Json))
          jAll = AddJSONMember(JSONValue(Json), "all")
          SetJSONArray(jAll)
          ForEach *FoundArea\all_entities()
            jEnt = AddJSONElement(jAll)
            SetJSONObject(jEnt)
            SetJSONString(AddJSONMember(jEnt, "id"), *FoundArea\all_entities()\id)
            SetJSONString(AddJSONMember(jEnt, "name"), *FoundArea\all_entities()\name)
          Next
          
          jVisible = AddJSONMember(JSONValue(Json), "visible")
          SetJSONArray(jVisible)
          If FindMapElement(AreaConfigs(), CurrentSettingsAreaID)
            ForEach AreaConfigs()\visible_entities()
              SetJSONString(AddJSONElement(jVisible), AreaConfigs()\visible_entities())
            Next
          EndIf
          
          jLabels = AddJSONMember(JSONValue(Json), "labels")
          SetJSONObject(jLabels)
          ForEach *FoundArea\all_entities()
            If FindMapElement(EntityLabels(), *FoundArea\all_entities()\id) And Trim(EntityLabels()) <> ""
              SetJSONString(AddJSONMember(jLabels, *FoundArea\all_entities()\id), EntityLabels())
            EndIf
          Next
          
          Script = "init(" + ComposeJSON(Json) + ")"
          WebViewExecuteScript(#Web_Settings, Script)
          FreeJSON(Json)
          ; Debug "DEBUG: WebViewExecuteScript ausgeführt."
        EndIf
      Else
        ; Debug "DEBUG: Fehler - Bereich " + CurrentSettingsAreaID + " nicht gefunden!"
      EndIf
    EndIf
    
  ElseIf Event = #Event_AreasLoaded
    LockMutex(FetchMutex)
    PayloadCopy = LoadedAreasPayload
    LoadedAreasPayload = ""
    UnlockMutex(FetchMutex)
    
    If LoadAreasFromPayload(PayloadCopy)
      RefreshGUI()
      UpdateMainLoadingUI(#False, "")
    Else
      Debug "Bereichsdaten konnten nicht geparst werden."
      UpdateMainLoadingUI(#False, T("MSG_DATA_PARSE_FAILED", "Data could not be processed."))
    EndIf
    
  ElseIf Event = #Event_AreasLoadFailed
    LockMutex(FetchMutex)
    ErrorCopy = LoadedAreasError
    UnlockMutex(FetchMutex)
    
    If ErrorCopy = ""
      ErrorCopy = T("MSG_UNKNOWN_LOAD_ERROR", "Unknown loading error.")
    EndIf
    Debug ErrorCopy
    UpdateMainLoadingUI(#False, ErrorCopy)
    
  ElseIf Event = #Event_ToggleEntity
    If ToggleEntityID <> ""
      ToggleDomain = ToggleEntityDomain
      If ToggleDomain = ""
        ToggleDomain = LCase(StringField(ToggleEntityID, 1, "."))
      EndIf
      
      ToggleEntityState = LCase(ToggleEntityState)
      If (ToggleEntityState = "on" Or ToggleEntityState = "off") And (ToggleDomain = "switch" Or ToggleDomain = "light" Or ToggleDomain = "input_boolean")
        If Not StartToggleRequest(ToggleEntityID, ToggleEntityState, ToggleDomain)
          UpdateMainLoadingUI(#False, T("MSG_TOGGLE_ALREADY_RUNNING", "Switching is already in progress..."))
        EndIf
      EndIf
      
      ToggleEntityID = ""
      ToggleEntityDomain = ""
      ToggleEntityState = ""
    EndIf
    
  ElseIf Event = #Event_ToggleDone
    UpdateMainLoadingUI(#False, "")
    StartAreasRefresh()
    
  ElseIf Event = #Event_ToggleFailed
    ErrorCopy = ""
    LockMutex(ToggleMutex)
    ErrorCopy = ToggleResultMessage
    UnlockMutex(ToggleMutex)
    If ErrorCopy = ""
      ErrorCopy = T("MSG_TOGGLE_FAILED", "Switching failed.")
    EndIf
    UpdateMainLoadingUI(#False, ErrorCopy)
    
  ElseIf Event = #Event_DesignLayout
    If DesignLayoutData <> ""
      Json = ParseJSON(#PB_Any, DesignLayoutData)
      If Json
        RootVal = JSONValue(Json)
        If RootVal And JSONType(RootVal) = #PB_JSON_Array And JSONArraySize(RootVal) > 0
          Arg0Val = GetJSONElement(RootVal, 0)
          If Arg0Val And JSONType(Arg0Val) = #PB_JSON_String
            DesignAction = LCase(GetJSONString(Arg0Val))
            
            If DesignAction = "visible" And JSONArraySize(RootVal) >= 3
              Arg1Val = GetJSONElement(RootVal, 1)
              Arg2Val = GetJSONElement(RootVal, 2)
              If Arg1Val And JSONType(Arg1Val) = #PB_JSON_String
                DesignAreaID = GetJSONString(Arg1Val)
                VisibleFlag = 1
                If Arg2Val
                  Select JSONType(Arg2Val)
                    Case #PB_JSON_Number
                      VisibleFlag = Bool(GetJSONInteger(Arg2Val) <> 0)
                    Case #PB_JSON_Boolean
                      VisibleFlag = Bool(GetJSONBoolean(Arg2Val))
                    Case #PB_JSON_String
                      VisibleFlag = Bool(Val(GetJSONString(Arg2Val)) <> 0)
                  EndSelect
                EndIf
                
                If DesignAreaID <> ""
                  AreaConfigs(DesignAreaID)\area_id = DesignAreaID
                  AreaConfigs(DesignAreaID)\visible = VisibleFlag
                  If AreaConfigs(DesignAreaID)\order <= 0
                    AreaConfigs(DesignAreaID)\order = 1
                  EndIf
                  SaveConfig()
                  RefreshGUI()
                EndIf
              EndIf
              
            ElseIf DesignAction = "reorder" And JSONArraySize(RootVal) >= 2
              Arg1Val = GetJSONElement(RootVal, 1)
              If Arg1Val And JSONType(Arg1Val) = #PB_JSON_Array
                OrderPos = 1
                For i = 0 To JSONArraySize(Arg1Val) - 1
                  Arg2Val = GetJSONElement(Arg1Val, i)
                  If Arg2Val And JSONType(Arg2Val) = #PB_JSON_String
                    DesignAreaID = GetJSONString(Arg2Val)
                    If DesignAreaID <> ""
                      AreaConfigs(DesignAreaID)\area_id = DesignAreaID
                      AreaConfigs(DesignAreaID)\order = OrderPos
                      If AreaConfigs(DesignAreaID)\visible <> 0 And AreaConfigs(DesignAreaID)\visible <> 1
                        AreaConfigs(DesignAreaID)\visible = 1
                      EndIf
                      OrderPos + 1
                    EndIf
                  EndIf
                Next
                SaveConfig()
                RefreshGUI()
              EndIf
              
            ElseIf DesignAction = "entity_order" And JSONArraySize(RootVal) >= 3
              Arg1Val = GetJSONElement(RootVal, 1)
              Arg2Val = GetJSONElement(RootVal, 2)
              If Arg1Val And Arg2Val And JSONType(Arg1Val) = #PB_JSON_String And JSONType(Arg2Val) = #PB_JSON_Array
                DesignAreaID = GetJSONString(Arg1Val)
                If DesignAreaID <> ""
                  AreaConfigs(DesignAreaID)\area_id = DesignAreaID
                  If AreaConfigs(DesignAreaID)\visible <> 0 And AreaConfigs(DesignAreaID)\visible <> 1
                    AreaConfigs(DesignAreaID)\visible = 1
                  EndIf
                  If AreaConfigs(DesignAreaID)\order <= 0
                    AreaConfigs(DesignAreaID)\order = 1
                  EndIf
                  
                  ClearList(AreaConfigs(DesignAreaID)\visible_entities())
                  For i = 0 To JSONArraySize(Arg2Val) - 1
                    Arg0Val = GetJSONElement(Arg2Val, i)
                    If Arg0Val And JSONType(Arg0Val) = #PB_JSON_String
                      If GetJSONString(Arg0Val) <> ""
                        AddElement(AreaConfigs(DesignAreaID)\visible_entities())
                        AreaConfigs(DesignAreaID)\visible_entities() = GetJSONString(Arg0Val)
                      EndIf
                    EndIf
                  Next
                  
                  SaveConfig()
                  RefreshGUI()
                EndIf
              EndIf
            EndIf
          EndIf
        EndIf
        FreeJSON(Json)
      EndIf
      DesignLayoutData = ""
    EndIf
    
  ElseIf Event = #PB_Event_CloseWindow
    If Window = #Win_Main
      If FetchThread
        WaitThread(FetchThread, 2000)
      EndIf
      If ToggleThread
        WaitThread(ToggleThread, 2000)
      EndIf
      End
    ElseIf Window = #Win_Settings
      HideWindow(#Win_Settings, #True)
      CurrentSettingsAreaID = ""
      If IsWindow(#Win_Main)
        DisableWindow(#Win_Main, #False)
      EndIf
    EndIf
  EndIf
  
Until Event = #PB_Event_CloseWindow And Window = #Win_Main

End
; IDE Options = PureBasic 6.30 - C Backend (MacOS X - arm64)
; CursorPosition = 98
; FirstLine = 70
; Folding = bTA+-----
; EnableThread
; EnableXP
; DPIAware
; Executable = /Users/peter/Applications/myApps/HA QuickView/HA QuickView.app
