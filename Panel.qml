import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "max.security-camera"
  ipcTarget: "max.security-camera"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  property var cameras: []
  property string activeId: ""
  readonly property var activeCamera: cameras.find(function(camera) { return camera.id === root.activeId }) || null
  readonly property string cameraName: activeCamera ? activeCamera.name : "Câmeras de segurança"
  property bool managing: false
  property bool editing: false
  property string editingId: ""
  property string removingId: ""
  property string saveError: ""
  property bool configLoaded: false
  property int previewGeneration: 0
  property bool previewDirty: false
  readonly property bool wantsPreview: opened && !managing && configLoaded && activeCamera !== null
  property string configError: ""
  property bool hasFrame: false
  property int frontFrame: -1
  readonly property string controlPath: Qt.resolvedUrl("camera-control").toString().replace(/^file:\/\//, "")
  readonly property string runtimePath: Quickshell.env("XDG_RUNTIME_DIR") + "/omarchy-security-camera"

  function open() {
    managing = false
    editing = false
    root.controller.show()
  }

  function close() {
    root.controller.hide()
    urlField.text = ""
  }

  function toggle() {
    if (opened) close()
    else open()
  }

  function startPreview() {
    previewGeneration++
    hasFrame = false
    frontFrame = -1
    refreshTimer.stop()
    previewA.source = ""
    previewB.source = ""
    previewDirty = true
    updatePreview()
  }

  function updatePreview() {
    if (previewProcess.running || snapshotProcess.running || !previewDirty) return
    previewDirty = false
    previewProcess.generation = previewGeneration
    previewProcess.command = [controlPath, wantsPreview ? "start" : "stop"]
    previewProcess.running = true
  }

  onWantsPreviewChanged: startPreview()
  Component.onDestruction: Quickshell.execDetached([controlPath, "stop"])

  function reloadFrame() {
    if (snapshotProcess.running || !wantsPreview) return
    snapshotProcess.generation = previewGeneration
    snapshotProcess.targetFrame = frontFrame === 0 ? 1 : 0
    snapshotProcess.command = [controlPath, "snapshot",
      snapshotProcess.targetFrame === 0 ? "a" : "b"]
    snapshotProcess.running = true
  }

  function openPlayer() {
    if (activeCamera && !saveProcess.running && !openProcess.running) openProcess.running = true
  }

  function manageCameras() {
    managing = true
    editing = false
    removingId = ""
    saveError = ""
    if (cameras.length === 0) editCamera(null)
  }

  function editCamera(camera) {
    editingId = camera ? camera.id : ""
    nameField.text = camera ? camera.name : ""
    urlField.text = camera ? camera.url : ""
    removingId = ""
    saveError = ""
    editing = true
    Qt.callLater(function() { nameField.forceActiveFocus() })
  }

  function persist(nextCameras, selectedId) {
    if (saveProcess.running || !configLoaded) return
    saveError = ""
    saveProcess.payload = JSON.stringify({cameras: nextCameras, activeId: selectedId})
    saveProcess.running = true
  }

  function saveCamera() {
    var name = nameField.text.trim()
    if (name === "") {
      saveError = "Informe um nome para a câmera."
      nameField.forceActiveFocus()
      return
    }
    var url = urlField.text.trim()
    if (!/^rtsps?:\/\/[^\s/]+(?:\/[^\s]*)?$/i.test(url)) {
      saveError = "Cole a URL completa: rtsp://usuario:senha@ip:554/caminho"
      return
    }
    var next = cameras.slice()
    var id = editingId || "camera-" + Date.now().toString(36)
    var index = next.findIndex(function(camera) { return camera.id === id })
    var camera = {id: id, name: name, url: url}
    if (index >= 0) next[index] = camera
    else next.push(camera)
    persist(next, id)
  }

  function removeCamera(id) {
    var next = cameras.filter(function(camera) { return camera.id !== id })
    persist(next, activeId === id ? (next.length ? next[0].id : "") : activeId)
  }

  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function")
      return bar.switchPanelFrom(barIdentity, direction)
    return false
  }

  FileView {
    id: configFile
    path: ""
    watchChanges: true
    printErrors: true
    onLoaded: {
      try {
        var config = JSON.parse(text())
        var next = Array.isArray(config.cameras) ? config.cameras
          : (config.url ? [{id: "legacy", name: String(config.name || "Câmera residencial"), url: String(config.url)}] : [])
        var previousUrl = root.activeCamera ? root.activeCamera.url : ""
        root.cameras = next
        root.activeId = next.some(function(camera) { return camera.id === config.activeId })
          ? config.activeId : (next.length ? next[0].id : "")
        root.configError = ""
        root.configLoaded = true
        if (root.wantsPreview && previousUrl !== root.activeCamera.url) root.startPreview()
      } catch (error) {
        root.configLoaded = false
        root.configError = "Configuração da câmera inválida"
      }
    }
    onFileChanged: reload()
    onLoadFailed: {
      root.configLoaded = false
      root.configError = "Não foi possível ler o cadastro de câmeras"
    }
  }

  Process {
    id: initProcess
    command: [root.controlPath, "init"]
    running: true
    stdout: StdioCollector { id: configPathOutput; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.configError = "Não foi possível carregar o cadastro de câmeras"
        return
      }
      configFile.path = configPathOutput.text.trim()
    }
  }

  Process {
    id: saveProcess
    property string payload: ""
    command: [root.controlPath, "save"]
    stdinEnabled: true
    onStarted: {
      write(payload + "\n")
      payload = ""
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.saveError = "Não foi possível salvar. Confira a URL RTSP e tente novamente."
        return
      }
      root.editing = false
      root.removingId = ""
      urlField.text = ""
      configFile.reload()
    }
  }

  Process {
    id: previewProcess
    property int generation: 0
    command: []
    onExited: function(exitCode) {
      if (generation !== root.previewGeneration || root.previewDirty) {
        Qt.callLater(root.updatePreview)
        return
      }
      if (!root.wantsPreview) return
      if (exitCode !== 0) {
        root.configError = "Não foi possível iniciar a prévia"
        return
      }
      root.configError = ""
      refreshTimer.interval = 3500
      refreshTimer.start()
    }
  }

  Process {
    id: snapshotProcess
    property int targetFrame: 0
    property int generation: 0
    command: []
    onExited: function(exitCode) {
      Qt.callLater(root.updatePreview)
      if (generation !== root.previewGeneration || !root.wantsPreview) return
      if (exitCode !== 0) {
        root.configError = "Aguardando imagem da câmera…"
        return
      }
      var frameGeneration = generation
      var slot = targetFrame
      var target = targetFrame === 0 ? previewA : previewB
      target.source = ""
      Qt.callLater(function() {
        if (frameGeneration !== root.previewGeneration || !root.wantsPreview) return
        target.source = "file://" + root.runtimePath
          + (slot === 0 ? "/display-a.jpg" : "/display-b.jpg")
      })
    }
  }

  Process {
    id: openProcess
    command: [root.controlPath, "open"]
    onExited: function(exitCode) {
      if (exitCode === 0) root.close()
      else root.configError = "Não foi possível abrir o MPV"
    }
  }

  Timer {
    id: refreshTimer
    interval: 3500
    repeat: true
    onTriggered: {
      root.reloadFrame()
      if (interval !== 600) interval = 600
    }
  }

  KeyboardPanel {
    id: popup
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: content
    padding: Style.space(8)
    contentWidth: fittedContentWidth(Style.space(390))
    contentHeight: cappedContentHeight(Style.space(root.managing ? 370 : 290))

    Item {
      id: content
      anchors.fill: parent
      Keys.onEscapePressed: {
        if (root.editing) { root.editing = false; urlField.text = "" }
        else if (root.managing) root.managing = false
        else root.close()
      }

      Item {
        id: header
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: Style.space(34)

        Text {
          anchors.left: parent.left
          anchors.right: root.managing ? manageButton.left : openButton.left
          anchors.rightMargin: Style.spacing.sm
          anchors.verticalCenter: parent.verticalCenter
          text: root.managing ? (root.editing ? (root.editingId ? "Editar câmera" : "Adicionar câmera") : "Gerenciar câmeras") : root.cameraName
          textFormat: Text.PlainText
          color: Color.popups.text
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        Button {
          id: openButton
          anchors.right: manageButton.left
          anchors.rightMargin: Style.spacing.xs
          anchors.verticalCenter: parent.verticalCenter
          iconText: "\uf065"
          visible: !root.managing && root.activeCamera !== null
          tooltipText: "Abrir grande no MPV"
          onClicked: root.openPlayer()
        }

        Button {
          id: manageButton
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          iconText: root.managing ? "\uf060" : "\uf067"
          tooltipText: root.managing ? "Voltar" : "Adicionar e gerenciar câmeras"
          enabled: !saveProcess.running
          onClicked: {
            if (root.editing) { root.editing = false; urlField.text = "" }
            else if (root.managing) root.managing = false
            else root.manageCameras()
          }
        }
      }

      ListView {
        id: cameraTabs
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: header.bottom
        height: visible ? Style.space(34) : 0
        visible: !root.managing && root.cameras.length > 1
        orientation: ListView.Horizontal
        spacing: Style.spacing.xs
        clip: true
        model: root.cameras
        delegate: Button {
          required property var modelData
          text: modelData.name
          selected: modelData.id === root.activeId
          enabled: !saveProcess.running
          onClicked: root.persist(root.cameras, modelData.id)
        }
      }

      Column {
        id: manager
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        spacing: Style.spacing.sm
        visible: root.managing

        Text {
          visible: root.editing
          text: "Nome da câmera"
          color: Color.popups.text
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.body
        }

        TextField {
          id: nameField
          width: parent.width
          visible: root.editing
          enabled: !saveProcess.running
          placeholderText: "Ex.: Garagem, Portão, Quintal"
          selectByMouse: true
          onAccepted: urlField.forceActiveFocus()
        }

        Text {
          width: parent.width
          visible: root.editing
          text: "Cole a URL RTSP completa, incluindo usuário e senha."
          color: Color.popups.text
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.Wrap
        }

        TextField {
          id: urlField
          width: parent.width
          visible: root.editing
          enabled: !saveProcess.running
          placeholderText: "rtsp://usuario:senha@ip:554/caminho"
          selectByMouse: true
          onAccepted: root.saveCamera()
        }

        Row {
          visible: root.editing
          spacing: Style.spacing.sm
          Button {
            text: saveProcess.running ? "Salvando…" : "Salvar"
            bordered: true
            enabled: !saveProcess.running && nameField.text.trim() !== "" && urlField.text.trim() !== "" && root.configLoaded
            onClicked: root.saveCamera()
          }
          Button {
            text: "Cancelar"
            enabled: !saveProcess.running
            onClicked: { root.editing = false; urlField.text = ""; root.saveError = "" }
          }
        }

        Text {
          width: parent.width
          visible: root.saveError !== ""
          text: root.saveError
          color: Color.urgent
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.Wrap
        }

        Button {
          visible: !root.editing
          iconText: "\uf067"
          text: "Adicionar câmera"
          enabled: !saveProcess.running && root.configLoaded
          onClicked: root.editCamera(null)
        }

        Text {
          visible: !root.editing && root.cameras.length === 0
          text: "Nenhuma câmera cadastrada."
          color: Color.popups.text
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.body
        }

        ListView {
          width: parent.width
          height: Math.max(0, manager.height - y)
          visible: !root.editing
          clip: true
          spacing: Style.spacing.xs
          model: root.cameras
          delegate: Item {
            id: cameraRow
            required property var modelData
            width: ListView.view.width
            height: Style.space(40)
            Text {
              anchors.left: parent.left
              anchors.right: rowActions.left
              anchors.rightMargin: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter
              text: root.removingId === cameraRow.modelData.id ? "Remover " + cameraRow.modelData.name + "?" : cameraRow.modelData.name
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: Color.popups.text
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.body
            }
            Row {
              id: rowActions
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              enabled: !saveProcess.running
              Button {
                iconText: root.removingId === cameraRow.modelData.id ? "\uf060" : "\uf044"
                tooltipText: root.removingId === cameraRow.modelData.id ? "Cancelar" : "Editar nome e URL RTSP"
                onClicked: {
                  if (root.removingId === cameraRow.modelData.id) root.removingId = ""
                  else root.editCamera(cameraRow.modelData)
                }
              }
              Button {
                iconText: "\uf1f8"
                text: root.removingId === cameraRow.modelData.id ? "Remover" : ""
                tooltipText: "Remover câmera"
                foreground: root.removingId === cameraRow.modelData.id ? Color.urgent : Color.popups.text
                onClicked: {
                  if (root.removingId === cameraRow.modelData.id) root.removeCamera(cameraRow.modelData.id)
                  else root.removingId = cameraRow.modelData.id
                }
              }
            }
          }
        }
      }

      Rectangle {
        id: viewport
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: cameraTabs.bottom
        anchors.bottom: parent.bottom
        color: "#050607"
        radius: Math.max(4, Style.cornerRadius - 3)
        clip: true
        visible: !root.managing

        Image {
          id: previewA
          anchors.fill: parent
          visible: root.frontFrame === 0
          fillMode: Image.PreserveAspectFit
          cache: false
          asynchronous: true
          onStatusChanged: {
            if (status === Image.Ready && source !== "") {
              root.frontFrame = 0
              root.hasFrame = true
            }
          }
        }

        Image {
          id: previewB
          anchors.fill: parent
          visible: root.frontFrame === 1
          fillMode: Image.PreserveAspectFit
          cache: false
          asynchronous: true
          onStatusChanged: {
            if (status === Image.Ready && source !== "") {
              root.frontFrame = 1
              root.hasFrame = true
            }
          }
        }

        Column {
          anchors.centerIn: parent
          spacing: Style.spacing.sm
          visible: !root.hasFrame

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.configError !== "" ? "\uf071" : "\uf03d"
            color: root.configError !== "" ? Color.urgent : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.menuFamily
            font.pixelSize: Style.space(26)
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: viewport.width - Style.spacing.lg * 2
            text: root.configError !== "" ? root.configError : (root.activeCamera ? "Conectando…" : "Nenhuma câmera cadastrada.\nClique em + para adicionar.")
            textFormat: Text.PlainText
            color: root.configError !== "" ? Color.urgent : Color.foreground
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
          }
        }

        MouseArea {
          anchors.fill: parent
          enabled: root.activeCamera !== null
          cursorShape: Qt.PointingHandCursor
          onClicked: root.openPlayer()
        }

        Rectangle {
          visible: root.activeCamera !== null
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.margins: Style.spacing.sm
          width: openHint.implicitWidth + Style.spacing.md
          height: openHint.implicitHeight + Style.spacing.sm
          radius: height / 2
          color: "#b0000000"

          Text {
            id: openHint
            anchors.centerIn: parent
            text: "\uf065  Abrir grande"
            color: "white"
            font.family: root.bar ? root.bar.fontFamily : Style.font.menuFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
