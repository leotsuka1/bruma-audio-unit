import AppKit
import AudioToolbox
import CoreAudioKit
import UniformTypeIdentifiers

private struct BrumaModule {
    let title: String
    let shortTitle: String
    let parameterIDs: [String]
    let bypassID: String
    let accent: NSColor
}

private final class BrumaRootView: NSView {
    var layoutHandler: (() -> Void)?
    override func layout() {
        super.layout()
        layoutHandler?()
    }
}

private final class BrumaParameterRow: NSView {
    let titleLabel = NSTextField(labelWithString: "")
    let valueLabel = NSTextField(labelWithString: "")
    var slider: NSSlider?
    var popup: NSPopUpButton?
    var toggle: NSButton?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = NSColor(calibratedWhite: 0.73, alpha: 1)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        valueLabel.textColor = NSColor(calibratedRed: 0.42, green: 0.83, blue: 0.75, alpha: 1)
        addSubview(titleLabel)
        addSubview(valueLabel)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        titleLabel.frame = NSRect(x: 0, y: bounds.height - 18, width: bounds.width - 72, height: 16)
        valueLabel.alignment = .right
        valueLabel.frame = NSRect(x: bounds.width - 72, y: bounds.height - 18, width: 72, height: 16)
        if let slider {
            slider.frame = NSRect(x: -4, y: 4, width: bounds.width + 8, height: 26)
        }
        if let popup {
            popup.frame = NSRect(x: 0, y: 1, width: bounds.width, height: 28)
        }
        if let toggle {
            toggle.frame = NSRect(x: 0, y: 1, width: bounds.width, height: 24)
        }
    }
}

public final class AUv3FilterDemoViewController: AUViewController {
    public var audioUnit: AUv3FilterDemo? {
        didSet {
            // AUAudioUnitFactory.createAudioUnit(with:) is allowed to run on
            // an XPC worker queue. AppKit view and Auto Layout mutations must
            // stay on the main thread or GarageBand can terminate the AU host.
            if Thread.isMainThread {
                updateInterfaceForAudioUnit()
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.updateInterfaceForAudioUnit()
                }
            }
        }
    }
    public var viewConfigurations: [AUAudioUnitViewConfiguration] {
        [AUAudioUnitViewConfiguration(width: 1040, height: 680, hostHasController: false)]
    }

    private let modules = [
        BrumaModule(title: "Ecualizador", shortTitle: "EQ", parameterIDs: ["eqLow", "eqMid", "eqMidFrequency", "eqMidQ", "eqHigh"], bypassID: "eqBypass", accent: NSColor(calibratedRed: 0.32, green: 0.72, blue: 0.83, alpha: 1)),
        BrumaModule(title: "Saturación", shortTitle: "DRIVE", parameterIDs: ["driveCharacter", "driveAmount", "driveTone", "driveMix"], bypassID: "driveBypass", accent: NSColor(calibratedRed: 0.91, green: 0.59, blue: 0.32, alpha: 1)),
        BrumaModule(title: "Compresor", shortTitle: "COMP", parameterIDs: ["compressorModel", "compressorThreshold", "compressorRatio", "compressorKnee", "compressorAttack", "compressorRelease", "compressorMakeup", "compressorTapeAmount", "compressorTapeSpeed"], bypassID: "compressorBypass", accent: NSColor(calibratedRed: 0.77, green: 0.63, blue: 0.91, alpha: 1)),
        BrumaModule(title: "Modulación", shortTitle: "MOD", parameterIDs: ["modType", "modRate", "modDepth", "modFeedback"], bypassID: "modBypass", accent: NSColor(calibratedRed: 0.35, green: 0.78, blue: 0.68, alpha: 1)),
        BrumaModule(title: "Delay", shortTitle: "DELAY", parameterIDs: ["delayTime", "delaySync", "delayDivision", "delayMode", "delayFeedback", "delayTone", "delayLowCut", "delayHighCut", "delayDucking", "delayMix", "delayWidth", "delayPingPong"], bypassID: "delayBypass", accent: NSColor(calibratedRed: 0.87, green: 0.75, blue: 0.38, alpha: 1)),
        BrumaModule(title: "Reverb híbrida", shortTitle: "REVERB", parameterIDs: ["reverbType", "reverbDecay", "reverbPredelay", "reverbDiffusion", "reverbEarlyLate", "reverbDamping", "reverbLowCut", "reverbHighCut", "reverbModRate", "reverbModDepth", "reverbWidth", "reverbDucking", "reverbFreeze", "reverbIRBlend", "reverbShimmer", "shimmerPitch", "reverbMix"], bypassID: "reverbBypass", accent: NSColor(calibratedRed: 0.32, green: 0.79, blue: 0.67, alpha: 1))
    ]

    private var reverbTypeValue: Int {
        Int((audioUnit?.parameterTree?.parameter(withAddress: 35)?.value ?? 1).rounded())
    }
    private var visibleParameterIDs: [String] {
        if selectedModule == 5 && reverbTypeValue == 6 {
            return ["reverbType", "reverseTime", "room", "reverseCurve", "reverseDensity", "reverseLiveness",
                    "reverseEndFade", "reverseLevel", "reverbPredelay", "reverbDiffusion", "reverbLowCut",
                    "reverbHighCut", "reverbWidth", "reverbDucking", "reverbMix"]
        }
        return modules[selectedModule].parameterIDs
    }

    private var rootView: BrumaRootView { view as! BrumaRootView }
    private let header = NSView()
    private let titleLabel = NSTextField(labelWithString: "BRUMA")
    private let subtitleLabel = NSTextField(labelWithString: "STEREO EFFECTS SUITE  /  AUv3")
    private let presetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let savePresetButton = NSButton(title: "Guardar", target: nil, action: nil)
    private let deletePresetButton = NSButton(title: "Eliminar", target: nil, action: nil)
    private let resetButton = NSButton(title: "Restablecer", target: nil, action: nil)
    private let rack = NSView()
    private let detailCard = NSView()
    private let moduleTitle = NSTextField(labelWithString: "")
    private let moduleSubtitle = NSTextField(labelWithString: "")
    private let bypassButton = NSButton(title: "ACTIVO", target: nil, action: nil)
    private let scrollView = NSScrollView()
    private let controlsDocument = NSView()
    private let masterCard = NSView()
    private let mixSlider = NSSlider(value: 28, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let mixValue = NSTextField(labelWithString: "28%")
    private let widthSlider = NSSlider(value: 100, minValue: 0, maxValue: 150, target: nil, action: nil)
    private let widthValue = NSTextField(labelWithString: "100%")
    private let outputSlider = NSSlider(value: 0, minValue: -24, maxValue: 12, target: nil, action: nil)
    private let outputValue = NSTextField(labelWithString: "0.0 dB")
    private let inputMeter = NSLevelIndicator()
    private let outputMeter = NSLevelIndicator()
    private let irButton = NSButton(title: "Cargar IR…", target: nil, action: nil)
    private let clearIRButton = NSButton(title: "Quitar", target: nil, action: nil)
    private let irLabel = NSTextField(labelWithString: "Sin respuesta de impulso cargada")
    private let statusLabel = NSTextField(labelWithString: "")
    private var isImportingIR = false
    private var irImportRequestID: UUID?
    private var selectedModule = 5
    private var moduleButtons: [NSButton] = []
    private var moduleBypassButtons: [NSButton] = []
    private var displayedReverbType: Int?
    private var parameterRows: [AUParameterAddress: BrumaParameterRow] = [:]
    private var parameterObserverToken: AUParameterObserverToken?
    private var observedParameterTree: AUParameterTree?
    private var meterTimer: Timer?
    private let backgroundColor = NSColor(calibratedRed: 0.045, green: 0.064, blue: 0.074, alpha: 1)
    private let cardColor = NSColor(calibratedRed: 0.075, green: 0.10, blue: 0.112, alpha: 1)
    private let mutedColor = NSColor(calibratedWhite: 0.55, alpha: 1)

    public override init(nibName: NSNib.Name?, bundle: Bundle?) {
        super.init(nibName: nil, bundle: nil)
    }
    public required init?(coder: NSCoder) { super.init(coder: coder) }

    public override func loadView() {
        let content = BrumaRootView(frame: NSRect(x: 0, y: 0, width: 1040, height: 680))
        content.wantsLayer = true
        content.layer?.backgroundColor = backgroundColor.cgColor
        content.layoutHandler = { [weak self] in self?.layoutInterface() }
        view = content
        makeInterface()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        updateInterfaceForAudioUnit()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.refreshMeters()
        }
    }

    deinit {
        meterTimer?.invalidate()
        if let parameterObserverToken, let tree = observedParameterTree {
            tree.removeParameterObserver(parameterObserverToken)
        }
    }

    public func toggleViewConfiguration() {}

    private func updateInterfaceForAudioUnit() {
        guard isViewLoaded else { return }
        if observedParameterTree !== audioUnit?.parameterTree {
            isImportingIR = false
            irImportRequestID = nil
            irButton.isEnabled = true
            if let token = parameterObserverToken { observedParameterTree?.removeParameterObserver(token) }
            observedParameterTree = audioUnit?.parameterTree
            parameterObserverToken = observedParameterTree?.token(byAddingParameterObserver: { [weak self, weak tree = observedParameterTree] _, _ in
                DispatchQueue.main.async {
                    guard let self, self.observedParameterTree === tree else { return }
                    self.syncControls()
                }
            })
        }
        rebuildRows()
        syncControls()
        refreshPresetMenu()
    }

    private func makeInterface() {
        let content = rootView
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor(calibratedRed: 0.065, green: 0.092, blue: 0.101, alpha: 1).cgColor
        content.addSubview(header)
        titleLabel.font = .systemFont(ofSize: 25, weight: .heavy)
        titleLabel.textColor = .white
        subtitleLabel.font = .systemFont(ofSize: 9, weight: .bold)
        subtitleLabel.textColor = NSColor(calibratedRed: 0.41, green: 0.79, blue: 0.72, alpha: 1)
        header.addSubview(titleLabel)
        header.addSubview(subtitleLabel)

        presetPopup.target = self
        presetPopup.action = #selector(presetChanged(_:))
        presetPopup.font = .systemFont(ofSize: 12, weight: .medium)
        header.addSubview(presetPopup)
        savePresetButton.target = self
        savePresetButton.action = #selector(saveUserPreset)
        savePresetButton.bezelStyle = .rounded
        header.addSubview(savePresetButton)
        deletePresetButton.target = self
        deletePresetButton.action = #selector(deleteCurrentUserPreset)
        deletePresetButton.bezelStyle = .rounded
        header.addSubview(deletePresetButton)
        resetButton.target = self
        resetButton.action = #selector(resetToDefault)
        resetButton.bezelStyle = .rounded
        header.addSubview(resetButton)

        content.addSubview(rack)
        for (index, module) in modules.enumerated() {
            let card = NSView()
            card.wantsLayer = true
            card.layer?.backgroundColor = cardColor.cgColor
            card.layer?.cornerRadius = 9
            rack.addSubview(card)

            let select = NSButton(title: module.shortTitle, target: self, action: #selector(selectModule(_:)))
            select.tag = index
            select.isBordered = false
            select.font = .systemFont(ofSize: 11, weight: .bold)
            select.contentTintColor = module.accent
            card.addSubview(select)
            moduleButtons.append(select)

            let toggle = NSButton(title: "ON", target: self, action: #selector(toggleModule(_:)))
            toggle.tag = index
            toggle.setButtonType(.toggle)
            toggle.isBordered = false
            toggle.font = .systemFont(ofSize: 9, weight: .bold)
            toggle.contentTintColor = NSColor(calibratedRed: 0.42, green: 0.83, blue: 0.75, alpha: 1)
            card.addSubview(toggle)
            moduleBypassButtons.append(toggle)
        }

        detailCard.wantsLayer = true
        detailCard.layer?.backgroundColor = cardColor.cgColor
        detailCard.layer?.cornerRadius = 13
        content.addSubview(detailCard)
        moduleTitle.font = .systemFont(ofSize: 19, weight: .bold)
        moduleTitle.textColor = .white
        moduleSubtitle.font = .systemFont(ofSize: 10, weight: .medium)
        moduleSubtitle.textColor = mutedColor
        detailCard.addSubview(moduleTitle)
        detailCard.addSubview(moduleSubtitle)
        bypassButton.target = self
        bypassButton.action = #selector(toggleSelectedModule)
        bypassButton.setButtonType(.toggle)
        bypassButton.bezelStyle = .rounded
        detailCard.addSubview(bypassButton)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.documentView = controlsDocument
        detailCard.addSubview(scrollView)

        masterCard.wantsLayer = true
        masterCard.layer?.backgroundColor = NSColor(calibratedRed: 0.085, green: 0.12, blue: 0.13, alpha: 1).cgColor
        masterCard.layer?.cornerRadius = 12
        content.addSubview(masterCard)
        addMasterControl("MIX GLOBAL", slider: mixSlider, value: mixValue, address: 0, x: 18, width: 155)
        addMasterControl("ANCHO", slider: widthSlider, value: widthValue, address: 5, x: 190, width: 145)
        addMasterControl("SALIDA", slider: outputSlider, value: outputValue, address: 50, x: 350, width: 145)

        let inputTitle = label("IN", 9, .bold, mutedColor)
        let outputTitle = label("OUT", 9, .bold, mutedColor)
        masterCard.addSubview(inputTitle)
        masterCard.addSubview(outputTitle)
        inputMeter.minValue = 0; inputMeter.maxValue = 1; inputMeter.warningValue = 0.72; inputMeter.criticalValue = 0.9
        outputMeter.minValue = 0; outputMeter.maxValue = 1; outputMeter.warningValue = 0.72; outputMeter.criticalValue = 0.9
        inputMeter.levelIndicatorStyle = .continuousCapacity
        outputMeter.levelIndicatorStyle = .continuousCapacity
        inputMeter.fillColor = NSColor(calibratedRed: 0.34, green: 0.79, blue: 0.66, alpha: 1)
        outputMeter.fillColor = NSColor(calibratedRed: 0.35, green: 0.75, blue: 0.85, alpha: 1)
        masterCard.addSubview(inputMeter)
        masterCard.addSubview(outputMeter)
        inputTitle.identifier = NSUserInterfaceItemIdentifier("inputTitle")
        outputTitle.identifier = NSUserInterfaceItemIdentifier("outputTitle")

        irButton.target = self
        irButton.action = #selector(loadImpulseResponse)
        irButton.bezelStyle = .rounded
        clearIRButton.target = self
        clearIRButton.action = #selector(clearImpulseResponse)
        clearIRButton.bezelStyle = .rounded
        irLabel.font = .systemFont(ofSize: 10, weight: .medium)
        irLabel.textColor = mutedColor
        detailCard.addSubview(irButton)
        detailCard.addSubview(clearIRButton)
        detailCard.addSubview(irLabel)
        statusLabel.font = .systemFont(ofSize: 10, weight: .medium)
        statusLabel.textColor = NSColor(calibratedRed: 0.94, green: 0.69, blue: 0.36, alpha: 1)
        detailCard.addSubview(statusLabel)
        content.needsLayout = true
    }

    private func addMasterControl(_ title: String, slider: NSSlider, value: NSTextField,
                                  address: AUParameterAddress, x: CGFloat, width: CGFloat) {
        let heading = label(title, 9, .bold, mutedColor)
        masterCard.addSubview(heading)
        slider.tag = Int(address)
        slider.target = self
        slider.action = #selector(masterSliderChanged(_:))
        slider.isContinuous = true
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        value.textColor = .white
        value.alignment = .right
        masterCard.addSubview(slider)
        masterCard.addSubview(value)
        heading.identifier = NSUserInterfaceItemIdentifier("master_\(address)_heading")
        heading.frame = NSRect(x: x, y: 79, width: width, height: 14)
        slider.frame = NSRect(x: x - 3, y: 38, width: width + 6, height: 27)
        value.frame = NSRect(x: x, y: 17, width: width, height: 15)
    }

    private func layoutInterface() {
        let width = rootView.bounds.width, height = rootView.bounds.height
        header.frame = NSRect(x: 0, y: height - 88, width: width, height: 88)
        titleLabel.frame = NSRect(x: 28, y: 39, width: 220, height: 32)
        subtitleLabel.frame = NSRect(x: 30, y: 22, width: 240, height: 14)
        presetPopup.frame = NSRect(x: max(300, width - 535), y: 31, width: 260, height: 28)
        savePresetButton.frame = NSRect(x: width - 267, y: 31, width: 78, height: 28)
        deletePresetButton.frame = NSRect(x: width - 183, y: 31, width: 72, height: 28)
        resetButton.frame = NSRect(x: width - 105, y: 31, width: 82, height: 28)

        let margin: CGFloat = 22
        let rackY = height - 154
        rack.frame = NSRect(x: margin, y: rackY, width: width - margin * 2, height: 54)
        let gap: CGFloat = 10
        let cardWidth = (rack.bounds.width - gap * CGFloat(modules.count - 1)) / CGFloat(modules.count)
        for i in modules.indices {
            let card = rack.subviews[i]
            card.frame = NSRect(x: CGFloat(i) * (cardWidth + gap), y: 0, width: cardWidth, height: 54)
            moduleButtons[i].frame = NSRect(x: 5, y: 21, width: cardWidth - 10, height: 25)
            moduleBypassButtons[i].frame = NSRect(x: 5, y: 2, width: cardWidth - 10, height: 18)
        }

        let masterHeight: CGFloat = 112
        masterCard.frame = NSRect(x: margin, y: 20, width: width - margin * 2, height: masterHeight)
        let meterStart = min(640, max(535, masterCard.bounds.width - 340))
        for child in masterCard.subviews {
            if child.identifier?.rawValue == "inputTitle" { child.frame = NSRect(x: meterStart, y: 81, width: 35, height: 12) }
            if child.identifier?.rawValue == "outputTitle" { child.frame = NSRect(x: meterStart, y: 39, width: 35, height: 12) }
        }
        inputMeter.frame = NSRect(x: meterStart + 42, y: 78, width: masterCard.bounds.width - meterStart - 62, height: 18)
        outputMeter.frame = NSRect(x: meterStart + 42, y: 36, width: masterCard.bounds.width - meterStart - 62, height: 18)

        let detailY = 20 + masterHeight + 12
        detailCard.frame = NSRect(x: margin, y: detailY, width: width - margin * 2, height: max(250, height - detailY - (height - rackY + 12)))
        moduleTitle.frame = NSRect(x: 22, y: detailCard.bounds.height - 39, width: 300, height: 25)
        moduleSubtitle.frame = NSRect(x: 24, y: detailCard.bounds.height - 57, width: 500, height: 13)
        bypassButton.frame = NSRect(x: detailCard.bounds.width - 112, y: detailCard.bounds.height - 46, width: 88, height: 27)
        irButton.frame = NSRect(x: 22, y: detailCard.bounds.height - 92, width: 102, height: 25)
        clearIRButton.frame = NSRect(x: 130, y: detailCard.bounds.height - 92, width: 65, height: 25)
        irLabel.frame = NSRect(x: 205, y: detailCard.bounds.height - 89, width: detailCard.bounds.width - 230, height: 18)
        statusLabel.frame = NSRect(x: 22, y: detailCard.bounds.height - 115, width: detailCard.bounds.width - 44, height: 15)
        scrollView.frame = NSRect(x: 22, y: 13, width: detailCard.bounds.width - 44, height: max(130, detailCard.bounds.height - (selectedModule == 5 ? 135 : 105)))
        layoutRows()
    }

    private func rebuildRows() {
        guard isViewLoaded, let tree = audioUnit?.parameterTree else { return }
        for row in parameterRows.values { row.removeFromSuperview() }
        parameterRows.removeAll()
        let module = modules[selectedModule]
        var rowIndex = 0
        let sortedDefinitions = AUv3FilterDemo.displayParameters
        displayedReverbType = reverbTypeValue
        for identifier in visibleParameterIDs {
            guard let definition = sortedDefinitions.first(where: { $0.identifier == identifier }),
                  let parameter = tree.parameter(withAddress: definition.address) else { continue }
            let row = BrumaParameterRow(frame: .zero)
            row.titleLabel.stringValue = definition.name
            switch identifier {
            case "reverseTime": row.toolTip = "Duración de la nube de reflexiones, de 50 a 2000 ms."
            case "room": row.toolTip = "Cambia la separación de las reflexiones dentro de la duración elegida."
            case "reverseCurve": row.toolTip = "Más curva concentra la subida de volumen cerca del final."
            case "reverseDensity": row.toolTip = "Más densidad añade reflexiones para una nube más tupida."
            case "reverseLiveness": row.toolTip = "Aumenta la presencia y el cuerpo de las reflexiones."
            case "reverseEndFade": row.toolTip = "Suaviza el cierre; se limita a la última mitad de la duración."
            case "reverseLevel": row.toolTip = "Ganancia de la señal reverse antes de mezclarla con la señal directa."
            default: break
            }
            if let strings = parameter.valueStrings {
                let popup = NSPopUpButton(frame: .zero, pullsDown: false)
                popup.addItems(withTitles: strings)
                popup.tag = Int(parameter.address)
                popup.target = self
                popup.action = #selector(enumChanged(_:))
                row.popup = popup
                row.addSubview(popup)
            } else if parameter.unit == .boolean {
                let toggle = NSButton(title: "Activado", target: self, action: #selector(toggleChanged(_:)))
                toggle.setButtonType(.toggle)
                toggle.tag = Int(parameter.address)
                row.toggle = toggle
                row.addSubview(toggle)
            } else {
                let slider = NSSlider(value: Double(parameter.value), minValue: Double(parameter.minValue),
                                      maxValue: Double(parameter.maxValue), target: self, action: #selector(parameterSliderChanged(_:)))
                slider.isContinuous = true
                slider.tag = Int(parameter.address)
                row.slider = slider
                row.addSubview(slider)
            }
            controlsDocument.addSubview(row)
            parameterRows[parameter.address] = row
            rowIndex += 1
        }
        let isReverb = selectedModule == 5
        let isReverse = isReverb && reverbTypeValue == 6
        irButton.isHidden = !isReverb || isReverse
        clearIRButton.isHidden = !isReverb || isReverse
        irLabel.isHidden = !isReverb || isReverse
        statusLabel.isHidden = !isReverb && audioUnit?.hasMissingImpulseResponse != true
        moduleTitle.stringValue = isReverse ? "REVERSE GATE" : module.title.uppercased()
        moduleTitle.textColor = module.accent
        moduleSubtitle.stringValue = isReverse ? "REVERSE GATE  •  REFLEXIONES ASCENDENTES  •  FINAL AJUSTABLE" : isReverb
            ? "FDN ESTÉREO  •  COLA MODULADA  •  CONVOLUCIÓN DE IR"
            : "Cadena fija  •  Control por módulo  •  Parámetros automatizables"
        bypassButton.title = "ACTIVO"
        syncControls()
        rootView.needsLayout = true
        layoutRows()
        rootView.layoutSubtreeIfNeeded()
        let top = max(0, controlsDocument.bounds.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: top))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func layoutRows() {
        guard isViewLoaded else { return }
        let width = max(1, scrollView.bounds.width)
        let columnGap: CGFloat = 34
        let colWidth = (width - columnGap) / 2
        let rowHeight: CGFloat = 68
        let count = parameterRows.count
        let rowCount = (count + 1) / 2
        controlsDocument.frame = NSRect(x: 0, y: 0, width: width, height: CGFloat(rowCount) * rowHeight + 12)
        for (index, identifier) in visibleParameterIDs.enumerated() {
            guard let definition = AUv3FilterDemo.displayParameters.first(where: { $0.identifier == identifier }),
                  let row = parameterRows[definition.address] else { continue }
            let column = index % 2
            let rowNumber = index / 2
            let y = controlsDocument.bounds.height - CGFloat(rowNumber + 1) * rowHeight
            row.frame = NSRect(x: CGFloat(column) * (colWidth + columnGap), y: y, width: colWidth, height: rowHeight)
        }
    }

    private func syncControls() {
        guard let tree = audioUnit?.parameterTree else { return }
        if selectedModule == 5, displayedReverbType != reverbTypeValue {
            rebuildRows()
            return
        }
        for (address, row) in parameterRows {
            guard let parameter = tree.parameter(withAddress: address) else { continue }
            if let slider = row.slider {
                slider.doubleValue = Double(parameter.value)
                row.valueLabel.stringValue = formattedValue(parameter)
            } else if let popup = row.popup {
                popup.selectItem(at: Int(parameter.value.rounded()))
                row.valueLabel.stringValue = ""
            } else if let toggle = row.toggle {
                toggle.state = parameter.value >= 0.5 ? .on : .off
                row.valueLabel.stringValue = toggle.state == .on ? "ON" : "OFF"
            }
        }
        if let mix = tree.parameter(withAddress: 0) {
            mixSlider.doubleValue = Double(mix.value)
            mixValue.stringValue = String(format: "%.0f%%", mix.value)
        }
        if let width = tree.parameter(withAddress: 5) {
            widthSlider.doubleValue = Double(width.value)
            widthValue.stringValue = String(format: "%.0f%%", width.value)
        }
        if let output = tree.parameter(withAddress: 50) {
            outputSlider.doubleValue = Double(output.value)
            outputValue.stringValue = String(format: "%.1f dB", output.value)
        }
        for (index, module) in modules.enumerated() {
            if let bypass = tree.parameter(withAddress: AUv3FilterDemo.address(for: module.bypassID)) {
                moduleBypassButtons[index].state = bypass.value < 0.5 ? .on : .off
                moduleBypassButtons[index].title = bypass.value < 0.5 ? "ON" : "BYPASS"
            }
        }
        if selectedModule < moduleBypassButtons.count {
            let bypassed = tree.parameter(withAddress: AUv3FilterDemo.address(for: modules[selectedModule].bypassID))?.value ?? 0
            bypassButton.title = bypassed < 0.5 ? "ACTIVO" : "BYPASS"
            bypassButton.state = bypassed < 0.5 ? .on : .off
        }
        updatePresetActions()
        updateIRStatus()
        refreshMeters()
    }

    private func formattedValue(_ parameter: AUParameter) -> String {
        if let strings = parameter.valueStrings {
            let index = Int(parameter.value.rounded())
            return strings.indices.contains(index) ? strings[index] : "—"
        }
        switch parameter.unit {
        case .seconds: return String(format: "%.2f s", parameter.value)
        case .milliseconds: return String(format: "%.0f ms", parameter.value)
        case .hertz:
            if parameter.value >= 1000 { return String(format: "%.1f kHz", parameter.value / 1000) }
            if parameter.value < 10 { return String(format: "%.2f Hz", parameter.value) }
            return String(format: "%.0f Hz", parameter.value)
        case .decibels: return String(format: "%.1f dB", parameter.value)
        case .percent: return String(format: "%.0f%%", parameter.value)
        default: return String(format: "%.2f", parameter.value)
        }
    }

    private func refreshMeters() {
        guard let audioUnit else { return }
        inputMeter.doubleValue = Double(min(1, audioUnit.inputLevel))
        outputMeter.doubleValue = Double(min(1, audioUnit.outputLevel))
    }

    private func updateIRStatus() {
        guard let audioUnit else { return }
        statusLabel.textColor = audioUnit.hasMissingImpulseResponse && reverbTypeValue != 6 ? .systemOrange : mutedColor
        if reverbTypeValue == 6 {
            statusLabel.stringValue = "Sube Curve para una entrada más tardía; Room cambia el espacio entre reflexiones."
            return
        }
        if isImportingIR {
            statusLabel.stringValue = "Preparando la IR…"
            return
        }
        if let name = audioUnit.impulseResponseName {
            irLabel.stringValue = audioUnit.hasMissingImpulseResponse ? "No encontrada: \(name)" : "IR: \(name)"
            irLabel.textColor = audioUnit.hasMissingImpulseResponse ? .systemOrange : mutedColor
            irButton.title = audioUnit.hasMissingImpulseResponse ? "Volver a enlazar…" : "Cambiar IR…"
            if audioUnit.hasMissingImpulseResponse {
                statusLabel.stringValue = "El proyecto conserva sus ajustes; elige el archivo IR para recuperarla."
            } else if let metadata = audioUnit.impulseResponseMetadata {
                statusLabel.stringValue = metadata.truncated
                    ? String(format: "IR: %.2f s de %.2f s; la cola algorítmica completa el espacio.", metadata.usedDuration, metadata.sourceDuration)
                    : String(format: "IR activa: %.2f s · %.0f kHz", metadata.usedDuration, metadata.sampleRate / 1000)
            }
        } else {
            irLabel.stringValue = "Sin respuesta de impulso cargada"
            irLabel.textColor = mutedColor
            irButton.title = "Cargar IR…"
            statusLabel.stringValue = "Los modos Room, Hall, Plate y Spring usan la reverb algorítmica estéreo."
        }
    }

    @objc private func selectModule(_ sender: NSButton) {
        guard modules.indices.contains(sender.tag) else { return }
        selectedModule = sender.tag
        for (index, button) in moduleButtons.enumerated() {
            button.font = .systemFont(ofSize: 11, weight: index == selectedModule ? .heavy : .semibold)
        }
        rebuildRows()
    }

    @objc private func toggleModule(_ sender: NSButton) {
        guard modules.indices.contains(sender.tag),
              let parameter = audioUnit?.parameterTree?.parameter(withAddress: AUv3FilterDemo.address(for: modules[sender.tag].bypassID)) else { return }
        parameter.setValue(sender.state == .on ? 0 : 1, originator: nil)
        syncControls()
    }

    @objc private func toggleSelectedModule() {
        guard let parameter = audioUnit?.parameterTree?.parameter(withAddress: AUv3FilterDemo.address(for: modules[selectedModule].bypassID)) else { return }
        parameter.setValue(parameter.value < 0.5 ? 1 : 0, originator: nil)
        syncControls()
    }

    @objc private func parameterSliderChanged(_ sender: NSSlider) {
        guard let parameter = audioUnit?.parameterTree?.parameter(withAddress: AUParameterAddress(sender.tag)) else { return }
        parameter.setValue(AUValue(sender.doubleValue), originator: nil)
        if let row = parameterRows[parameter.address] { row.valueLabel.stringValue = formattedValue(parameter) }
    }

    @objc private func enumChanged(_ sender: NSPopUpButton) {
        audioUnit?.parameterTree?.parameter(withAddress: AUParameterAddress(sender.tag))?
            .setValue(AUValue(sender.indexOfSelectedItem), originator: nil)
        if sender.tag == 35 { rebuildRows() }
    }

    @objc private func toggleChanged(_ sender: NSButton) {
        audioUnit?.parameterTree?.parameter(withAddress: AUParameterAddress(sender.tag))?
            .setValue(sender.state == .on ? 1 : 0, originator: nil)
    }

    @objc private func masterSliderChanged(_ sender: NSSlider) {
        audioUnit?.parameterTree?.parameter(withAddress: AUParameterAddress(sender.tag))?
            .setValue(AUValue(sender.doubleValue), originator: nil)
        syncControls()
    }

    @objc private func presetChanged(_ sender: NSPopUpButton) {
        guard let audioUnit else { return }
        let factory = audioUnit.factoryPresets
        let index = sender.indexOfSelectedItem
        if index >= 0 && index < factory.count {
            audioUnit.selectFactoryPreset(index)
        } else {
            let userIndex = index - factory.count - (audioUnit.brumaUserPresets.isEmpty ? 0 : 1)
            guard audioUnit.brumaUserPresets.indices.contains(userIndex) else { return }
            audioUnit.loadBrumaUserPreset(audioUnit.brumaUserPresets[userIndex])
        }
        syncControls()
        updatePresetActions()
    }

    @objc private func resetToDefault() {
        audioUnit?.resetToDefaultPreset()
        syncControls()
        refreshPresetMenu()
    }

    @objc private func saveUserPreset() {
        guard let audioUnit else { return }
        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        nameField.stringValue = "Mi preset"
        let alert = NSAlert()
        alert.messageText = "Guardar preset de Bruma"
        alert.informativeText = "Guarda los módulos, sus parámetros y la referencia a la IR activa."
        alert.addButton(withTitle: "Guardar")
        alert.addButton(withTitle: "Cancelar")
        alert.accessoryView = nameField
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            let saved = try audioUnit.saveBrumaUserPreset(named: name)
            audioUnit.loadBrumaUserPreset(saved)
            refreshPresetMenu()
            syncControls()
        } catch {
            showPresetError(error)
        }
    }

    @objc private func deleteCurrentUserPreset() {
        guard let audioUnit, let preset = audioUnit.currentPreset, preset.number < 0 else { return }
        guard let saved = audioUnit.brumaUserPresets.first(where: { $0.number == preset.number }) else { return }
        audioUnit.deleteBrumaUserPreset(saved)
        refreshPresetMenu()
        syncControls()
    }

    private func refreshPresetMenu() {
        guard isViewLoaded else { return }
        presetPopup.removeAllItems()
        presetPopup.addItems(withTitles: AUv3FilterDemo.presetDisplayNames)
        if let audioUnit, !audioUnit.brumaUserPresets.isEmpty {
            presetPopup.menu?.addItem(.separator())
            for preset in audioUnit.brumaUserPresets { presetPopup.addItem(withTitle: preset.name) }
        }
        if let audioUnit, let currentPreset = audioUnit.currentPreset {
            let factoryCount = audioUnit.factoryPresets.count
            if currentPreset.number < 0,
               let userIndex = audioUnit.brumaUserPresets.firstIndex(where: { $0.number == currentPreset.number }) {
                presetPopup.selectItem(at: factoryCount + 1 + userIndex)
            } else if currentPreset.number < factoryCount {
                presetPopup.selectItem(at: currentPreset.number)
            }
        }
        updatePresetActions()
    }

    private func updatePresetActions() {
        deletePresetButton.isEnabled = (audioUnit?.currentPreset?.number ?? 0) < 0
    }

    private func showPresetError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "No se pudo guardar el preset"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc private func loadImpulseResponse() {
        let panel = NSOpenPanel()
        panel.title = "Cargar respuesta de impulso"
        panel.allowedContentTypes = [.wav, .aiff, UTType(filenameExtension: "aif")!, UTType(filenameExtension: "aifc")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let importURL: URL? = panel.runModal() == .OK ? panel.url : nil
        guard let url = importURL else { return }
        guard let unit = audioUnit else { return }
        let requestID = UUID()
        irImportRequestID = requestID
        isImportingIR = true
        irButton.isEnabled = false
        statusLabel.stringValue = "Preparando la IR…"
        unit.loadImpulseResponseAsync(from: url) { [weak self, weak unit] result in
            guard let self, self.audioUnit === unit, self.irImportRequestID == requestID else { return }
            self.isImportingIR = false
            self.irImportRequestID = nil
            self.irButton.isEnabled = true
            self.updateIRStatus()
            self.syncControls()
            if case .failure(let error) = result, (error as NSError).code != NSUserCancelledError {
                let alert = NSAlert()
                alert.messageText = "No se pudo cargar la IR"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    @objc private func clearImpulseResponse() {
        isImportingIR = false
        irImportRequestID = nil
        irButton.isEnabled = true
        audioUnit?.clearImpulseResponse()
        updateIRStatus()
        syncControls()
    }

    private func label(_ text: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.isBezeled = false
        field.drawsBackground = false
        return field
    }
}
