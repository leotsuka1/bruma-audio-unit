import Cocoa
import AUv3FilterFramework

final class MainViewController: NSViewController {
    let audioUnitManager = AudioUnitManager()

    // Kept for the original storyboard connections; the redesigned preview
    // surface no longer exposes the Apple filter-demo controls.
    @IBOutlet weak var playButton: NSButton!
    @IBOutlet weak var toggleButton: NSButton!
    @IBOutlet weak var cutoffSlider: NSSlider!
    @IBOutlet weak var cutoffTextField: NSTextField!
    @IBOutlet weak var resonanceSlider: NSSlider!
    @IBOutlet weak var resonanceTextField: NSTextField!
    @IBOutlet weak var containerView: NSView!

    private let pluginContainer = NSView()

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1120, height: 780))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedRed: 0.035, green: 0.05, blue: 0.059, alpha: 1).cgColor

        let brand = NSTextField(labelWithString: "BRUMA")
        brand.font = .systemFont(ofSize: 15, weight: .heavy)
        brand.textColor = .white
        brand.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(brand)

        let caption = NSTextField(labelWithString: "AUv3 EFFECTS SUITE  •  PLUGIN PREVIEW")
        caption.font = .systemFont(ofSize: 9, weight: .bold)
        caption.textColor = NSColor(calibratedRed: 0.42, green: 0.79, blue: 0.72, alpha: 1)
        caption.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(caption)

        pluginContainer.wantsLayer = true
        pluginContainer.layer?.backgroundColor = NSColor(calibratedRed: 0.045, green: 0.064, blue: 0.074, alpha: 1).cgColor
        pluginContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(pluginContainer)

        NSLayoutConstraint.activate([
            brand.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            brand.topAnchor.constraint(equalTo: root.topAnchor, constant: 17),
            caption.leadingAnchor.constraint(equalTo: brand.leadingAnchor),
            caption.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 2),
            pluginContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            pluginContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            pluginContainer.topAnchor.constraint(equalTo: root.topAnchor, constant: 68),
            pluginContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14)
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        embedPlugInView()
        populatePresetMenu()
        audioUnitManager.delegate = self
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        view.window?.delegate = self
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if let window = view.window {
            window.title = "Bruma"
            window.minSize = NSSize(width: 1040, height: 720)
            window.setContentSize(NSSize(width: 1120, height: 780))
        }
    }

    private func embedPlugInView() {
        let controller = audioUnitManager.viewController!
        addChild(controller)
        let pluginView = controller.view
        pluginView.translatesAutoresizingMaskIntoConstraints = false
        pluginContainer.addSubview(pluginView)
        NSLayoutConstraint.activate([
            pluginView.leadingAnchor.constraint(equalTo: pluginContainer.leadingAnchor),
            pluginView.trailingAnchor.constraint(equalTo: pluginContainer.trailingAnchor),
            pluginView.topAnchor.constraint(equalTo: pluginContainer.topAnchor),
            pluginView.bottomAnchor.constraint(equalTo: pluginContainer.bottomAnchor)
        ])
    }

    private func populatePresetMenu() {
        guard let presetMenu = NSApplication.shared.mainMenu?.item(withTag: 666)?.submenu else { return }
        for preset in audioUnitManager.presets {
            let menuItem = NSMenuItem(title: preset.name, action: #selector(handleMenuSelection(_:)),
                                      keyEquivalent: "\(preset.number + 1)")
            menuItem.tag = preset.number
            presetMenu.addItem(menuItem)
        }
    }

    @objc private func handleMenuSelection(_ sender: NSMenuItem) {
        sender.menu?.items.forEach { $0.state = .off }
        sender.state = .on
        if let preset = audioUnitManager.presets.first(where: { $0.number == sender.tag }) {
            audioUnitManager.currentPreset = preset
        }
    }

    @IBAction func togglePlay(_ sender: NSButton) {
        audioUnitManager.togglePlayback()
    }

    @IBAction func toggleView(_ sender: NSButton) {
        audioUnitManager.toggleView()
    }

    @IBAction func cutoffSliderValueChanged(_ sender: NSSlider) {
        audioUnitManager.cutoffValue = sender.floatValue
    }

    @IBAction func resonanceSliderValueChanged(_ sender: NSSlider) {
        audioUnitManager.resonanceValue = sender.floatValue
    }
}

extension MainViewController: AUManagerDelegate {
    func cutoffValueDidChange(_ value: Float) {
        guard cutoffSlider != nil, cutoffTextField != nil else { return }
        cutoffSlider.floatValue = value
        cutoffTextField.stringValue = String(format: "%.0f", value)
    }
    func resonanceValueDidChange(_ value: Float) {
        guard resonanceSlider != nil, resonanceTextField != nil else { return }
        resonanceSlider.floatValue = value
        resonanceTextField.stringValue = String(format: "%.2f", value)
    }
}

extension MainViewController: NSWindowDelegate {}
