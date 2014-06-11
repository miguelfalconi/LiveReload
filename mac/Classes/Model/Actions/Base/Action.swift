
import Foundation

class Action : NSObject {

    let contextActionType: LRContextActionType

    var kind: ActionKind {
        return contextActionType.actionType.kind
    }

    var type: ActionType {
        return contextActionType.actionType
    }

    var label: String {
        return type.name
    }

    var project: Project {
        return contextActionType.project
    }

    var enabled: Bool = true {
        didSet {
            didChange()
        }
    }

    var nonEmpty: Bool {
        return true
    }

    var inputFilterOption: FilterOption = FilterOption(subfolder: "") {
        didSet {
            if (inputFilterOption != oldValue) {
                updateInputPathSpec()
                didChange()
            }
        }
    }

    var intrinsicInputPathSpec: ATPathSpec? {
        didSet {
            updateInputPathSpec()
        }
    }

    init(contextActionType: LRContextActionType, memento: NSDictionary?) {
        self.contextActionType = contextActionType
        self.primaryVersionSpec = LRVersionSpec.stableVersionSpecMatchingAnyVersionInVersionSpace(contextActionType.actionType.primaryVersionSpace)
        super.init()
        self.memento = memento ? swiftify(dictionary: memento!) : [:]

        loadFromMemento()
        _initEffectiveVersion()
    }

    deinit {
        stopObservingNotifications()
    }

    var theMemento: Dictionary<String, AnyObject> {
        get {
            updateMemento()
            return memento
        }
        set {
            memento = newValue
            loadFromMemento()
        }
    }

    var inputPathSpec: ATPathSpec = ATPathSpec.emptyPathSpec() // readonly

    var memento: Dictionary<String, AnyObject> = [:]
    var _options: Dictionary<String, AnyObject> = [:]

    func loadFromMemento() {
        enabled = boolValue(memento["enabled"], defaultValue: true)
        inputFilterOption = FilterOption(memento: NVCast(memento["filter"], "subdir:."))
        if let ver = stringValue(memento["version"]) {
            primaryVersionSpec = LRVersionSpec(string: ver, inVersionSpace:type.primaryVersionSpace)
        } else {
            primaryVersionSpec = LRVersionSpec.stableVersionSpecMatchingAnyVersionInVersionSpace(type.primaryVersionSpace)
        }
        if let opt = memento["options"].omap({ $0 as? NSDictionary }) {
            swiftify(dictionary: opt, into: &_options)
        }
    }

    func updateMemento() {
        memento["action"] = type.identifier
        memento["enabled"] = enabled
        memento["filter"] = inputFilterOption.memento
        memento["version"] = primaryVersionSpec.stringValue
        if _options.count > 0 {
            memento["options"] = _options
        } else {
            memento["options"] = nil
        }
    }

    func updateInputPathSpec() {
        var spec = inputFilterOption.pathSpec
        if spec {
            if (intrinsicInputPathSpec) {
                spec = ATPathSpec(matchingIntersectionOf: [spec!, intrinsicInputPathSpec!])
            }
        }
        inputPathSpec = spec
    }

    // MARK: Target selection

    var supportsFileTargets: Bool {
        return false
    }

    func targetForModifiedFiles(files: LRProjectFile[]) -> LRTarget? {
        return nil
    }

    func fileTargetForRootFile(file: LRProjectFile) -> LRTarget? {
        return nil
    }

    func fileTargetsForModifiedFiles(modifiedFiles: LRProjectFile[]) -> LRTarget[] {
        if !supportsFileTargets {
            return []
        }
        let matchingFiles = modifiedFiles.filter(inputPathSpecMatchesFile)
        let rootFiles = project.rootFilesForFiles(matchingFiles) as LRProjectFile[]
        let matchingRootFiles = rootFiles.filter(inputPathSpecMatchesFile)
        return matchingRootFiles.mapIf { self.fileTargetForRootFile($0) }
    }

    func inputPathSpecMatchesFiles(files: LRProjectFile[]) -> Bool {
        return files.any(inputPathSpecMatchesFile)
    }

    func inputPathSpecMatchesFile(file: LRProjectFile) -> Bool {
        return self.inputPathSpec.matchesPath(file.relativePath, type: ATPathSpecEntryType.File)
    }


    // MARK: Compilation

    func compileFile(file: LRProjectFile, result: LROperationResult, completionHandler: dispatch_block_t) {
    }

    func handleDeletionOfFile(file: LRProjectFile) {
    }

    func invokeWithModifiedFiles(files: LRProjectFile[], result: LROperationResult, completionHandler: dispatch_block_t) {
    }


    // MARK: Custom arguments

    var customArguments: String[] {
        get {
            return NVCast(_options["custom-args"], [])
        }
        set {
            setOptionValue((newValue.count > 0 ? newValue : nil), forKey: "custom-args")
        }
    }

    var customArgumentsString: String {
        get {
            return customArguments.quotedArgumentStringUsingBourneQuotingStyle
        }
        set {
            customArguments = newValue.argumentsArrayUsingBourneQuotingStyle
        }
    }


    // MARK: Options

    func optionValueForKey(key: String) -> AnyObject? {
        return _options[key]
    }

    func setOptionValue(value: AnyObject?, forKey key: String) {
        if _options[key] !== value {
            _options[key] = value
            didChange()
        }
    }


    // MARK: LROption objects

    func createOptions() -> LROption[] {
        var options: LROption[] = []
        options.append(LRVersionOption(manifest: ["id": "version", "label": "Version:"], action: self, errorSink: nil))
        if effectiveVersion {
            options.extend(effectiveVersion!.manifest.createOptionsWithAction(self) as LROption[])
        }
        options.append(LRCustomArgumentsOption(manifest: ["id": "custom-args"], action: self, errorSink: nil))
        return options
    }


    // MARK: Versions

    var primaryVersionSpec: LRVersionSpec {
        didSet {
            if (primaryVersionSpec != oldValue) {
                didChange()
                _updateEffectiveVersion()
            }
        }
    }

    var effectiveVersion: LRActionVersion?

    func _computeEffectiveVersion() -> LRActionVersion? {
        return findIf(contextActionType.versions as LRActionVersion[]) { self.primaryVersionSpec.matchesVersion($0.primaryVersion, withTag: LRVersionTag.Unknown) }
    }

    var _c_updateEffectiveVersion = Coalescence(delayMs: 0)
    func _updateEffectiveVersion() {
        _c_updateEffectiveVersion.performSync {
            self.effectiveVersion = self._computeEffectiveVersion()
            self.postNotification(LRActionPrimaryEffectiveVersionDidChangeNotification)
        }
    }

    func _initEffectiveVersion() {
        _c_updateEffectiveVersion.monitorBlock = weakify(self) { (me, active) in me.project.setAnalysisInProgress(active, forTask: me) }

        observeNotification(LRContextActionTypeDidChangeVersionsNotification, selector: "_updateEffectiveVersion")
        _updateEffectiveVersion()
    }

    var missingEffectiveVersionError: NSError {
        var available = join(", ", contextActionType.versions.map { $0.primaryVersion.description })
        return NSError(LRErrorDomain, LRErrorNoMatchingVersion, "No available version matched for version spec \(primaryVersionSpec), available versions: \(available)")
    }


    // MARK: Change notification

    // protected
    func didChange() {
        postNotification("SomethingChanged")
    }


    // MARK: Build

    func configureStep(step: ScriptInvocationStep) {
        step.project = project
        step.addValue(project.path, forSubstitutionKey: "project_dir")

        if let eff = effectiveVersion {
            let manifest = eff.manifest
            step.commandLine = manifest.commandLineSpec
            step.addValue(type.plugin.path as String, forSubstitutionKey: "plugin")

            for package in eff.packageSet.packages as LRPackage[] {
                step.addValue(package.sourceFolderURL.path, forSubstitutionKey: package.identifier)
                step.addValue(package.version.description, forSubstitutionKey: "\(package.identifier).ver")
            }
        }

        var additionalArguments: String[] = []
        for option in self.createOptions() {
            additionalArguments.extend(option.commandLineArguments as String[])
        }
        additionalArguments.extend(customArguments)

        step.addValue(additionalArguments as NSArray, forSubstitutionKey: "additional")
    }

    func configureResult(result: LROperationResult) {
        if let eff = effectiveVersion {
            result.errorSyntaxManifest = ["errors": eff.manifest.errorSpecs, "warnings": eff.manifest.warningSpecs]
        }
    }

}
