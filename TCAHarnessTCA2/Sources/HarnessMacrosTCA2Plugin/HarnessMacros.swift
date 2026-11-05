import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// Generates TCA 2 harness descriptors from `@Feature` source as written. `@Feature`'s own
// expansion (State/Action for enum features, `Scopes`) is not visible here, so generated code
// names those members and relies on the type checker: State fields with a matching action case
// are exactly the fields `@Feature` generates scope paths for.

private struct HarnessDiagnostic: DiagnosticMessage {
  let message: String
  var diagnosticID: MessageID { MessageID(domain: "TCAHarnessTCA2", id: "unsupported") }
  let severity: DiagnosticSeverity
}

private func diagnose(_ node: some SyntaxProtocol, _ message: String, in context: some MacroExpansionContext,
  severity: DiagnosticSeverity = .error) {
  context.diagnose(Diagnostic(node: Syntax(node), message: HarnessDiagnostic(message: message, severity: severity)))
}

private func attribute(_ attributes: AttributeListSyntax, _ name: String) -> AttributeSyntax? {
  for element in attributes {
    guard let attribute = element.as(AttributeSyntax.self) else { continue }
    let attributeName = attribute.attributeName.trimmedDescription
    if attributeName == name || attributeName.hasSuffix("." + name) { return attribute }
  }
  return nil
}

private func argument(_ attribute: AttributeSyntax?, _ label: String?) -> String? {
  guard let attribute, case let .argumentList(arguments) = attribute.arguments else { return nil }
  return arguments.first { $0.label?.text == label }?.expression.trimmedDescription
}

private func quoted(_ text: String) -> String { String(reflecting: text) }

/// `Child.Action` → `Child`.
private func featureType(fromAction type: String) -> String? {
  type.hasSuffix(".Action") ? String(type.dropLast(".Action".count)) : nil
}

private enum SpawnShape { case single, optional, array }

/// `Spawn<Child>`, `Spawn<Child>?`, `[Spawn<Child>]`, or an initializer `Spawn(Child.State(…))` /
/// `[Spawn<Child>]()`.
private func spawned(type: String?, initializer: String?) -> (String, SpawnShape)? {
  if let type {
    func inner(_ text: String) -> String? {
      text.hasPrefix("Spawn<") && text.hasSuffix(">") ? String(text.dropFirst("Spawn<".count).dropLast()) : nil
    }
    if let child = inner(type) { return (child, .single) }
    if type.hasSuffix("?"), let child = inner(String(type.dropLast())) { return (child, .optional) }
    if type.hasPrefix("Optional<"), type.hasSuffix(">"), let child = inner(String(type.dropFirst("Optional<".count).dropLast())) {
      return (child, .optional)
    }
    if type.hasPrefix("["), type.hasSuffix("]"), let child = inner(String(type.dropFirst().dropLast())) { return (child, .array) }
    return nil
  }
  if let initializer, initializer.hasPrefix("[Spawn<"), initializer.hasSuffix(">]()") {
    return (String(initializer.dropFirst("[Spawn<".count).dropLast(">]()".count)), .array)
  }
  guard let initializer, initializer.hasPrefix("Spawn("), let range = initializer.firstRange(of: ".State(") else { return nil }
  let child = initializer[initializer.index(initializer.startIndex, offsetBy: "Spawn(".count)..<range.lowerBound]
  return child.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." } ? (String(child), .single) : nil
}

private let sensitive: Set<String> = ["token", "accesstoken", "refreshtoken", "password", "apikey", "authorization"]

public struct MarkerMacro: PeerMacro {
  public static func expansion(of node: AttributeSyntax, providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext) throws -> [DeclSyntax] { [] }
}

public struct HarnessFeatureMacro: MemberMacro, ExtensionMacro {
  public static func expansion(of node: AttributeSyntax, attachedTo declaration: some DeclGroupSyntax,
    providingExtensionsOf type: some TypeSyntaxProtocol, conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext) throws -> [ExtensionDeclSyntax] {
    guard declaration.is(StructDeclSyntax.self) || declaration.is(EnumDeclSyntax.self) else { return [] }
    return [try ExtensionDeclSyntax("extension \(type.trimmed): HarnessFeatureProvider {}")]
  }

  public static func expansion(of node: AttributeSyntax, providingMembersOf declaration: some DeclGroupSyntax,
    conformingTo protocols: [TypeSyntax], in context: some MacroExpansionContext) throws -> [DeclSyntax] {
    let expression: String
    if let feature = declaration.as(EnumDeclSyntax.self) {
      expression = enumDescriptor(feature, in: context)
    } else if let feature = declaration.as(StructDeclSyntax.self) {
      guard let built = structDescriptor(feature, in: context) else { return [] }
      expression = built
    } else {
      diagnose(declaration, "@HarnessFeature requires a @Feature struct or @Feature enum", in: context)
      return []
    }
    var described = expression
    if case let .argumentList(arguments) = node.arguments,
      let dismiss = arguments.first(where: { $0.label?.text == "dismiss" }) {
      described += "\n.dismissible(\(dismiss.expression.trimmedDescription))"
    }
    return ["@MainActor public static var harnessDescriptor: FeatureDescriptor<State, Action> {\n\(raw: described)\n}"]
  }

  /// `@Feature enum Destination { case detail(ProjectDetail) }`: each feature case is a child
  /// reached with `store.scope(\.detail)` (or `store.spawn(\.detail)` for `Spawn<Child>` cases).
  static func enumDescriptor(_ feature: EnumDeclSyntax, in context: some MacroExpansionContext) -> String {
    var snapshots: [String] = []
    var chain: [String] = []
    for member in feature.memberBlock.members {
      guard let cases = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
      if attribute(cases.attributes, "HarnessIgnore") != nil || attribute(cases.attributes, "FeatureIgnored") != nil { continue }
      for element in cases.elements {
        let name = element.name.text
        guard let parameters = element.parameterClause?.parameters, parameters.count == 1, let parameter = parameters.first else {
          continue  // Not a feature case; it still appears through reflected observation.
        }
        let type = parameter.type.trimmedDescription
        if let (child, shape) = spawned(type: type, initializer: nil), shape == .single {
          snapshots.append("if case let .\(name)(value) = state { return .object([\"case\": .string(\(quoted(name))), \"value\": \(child).harnessDescriptor.snapshot(value.state)]) }")
          chain.append(".child(\(quoted(name)), descriptor: \(child).harnessDescriptor) { $0.spawn(\\.\(name)) }")
        } else {
          snapshots.append("if case let .\(name)(value) = state { return .object([\"case\": .string(\(quoted(name))), \"value\": \(type).harnessDescriptor.snapshot(value)]) }")
          chain.append(".child(\(quoted(name)), descriptor: \(type).harnessDescriptor) { $0.scope(\\.\(name)) }")
        }
      }
    }
    snapshots.append("return StateInspection.snapshot(state)")
    let observation = snapshots.map { "  " + $0 }.joined(separator: "\n")
    return "FeatureDescriptor<State, Action>(\(quoted(feature.name.text)), observation: { state in\n\(observation)\n})"
      + chain.map { "\n" + $0 }.joined()
  }

  struct ActionCase {
    let element: EnumCaseElementSyntax
    let attributes: AttributeListSyntax
    var parameters: [EnumCaseParameterSyntax] { element.parameterClause.map { Array($0.parameters) } ?? [] }
  }

  static func structDescriptor(_ feature: StructDeclSyntax, in context: some MacroExpansionContext) -> String? {
    let members = feature.memberBlock.members.map(\.decl)
    let stateStruct = members.compactMap { $0.as(StructDeclSyntax.self) }.first { $0.name.text == "State" }
    let stateEnum = members.compactMap { $0.as(EnumDeclSyntax.self) }.first { $0.name.text == "State" }
    let action = members.compactMap { $0.as(EnumDeclSyntax.self) }.first { $0.name.text == "Action" }
    if stateStruct == nil, stateEnum == nil, action == nil,
      members.contains(where: { $0.as(TypeAliasDeclSyntax.self).map { ["State", "Action"].contains($0.name.text) } ?? false }) {
      diagnose(feature, "@HarnessFeature requires locally declared State and Action; use an explicit FeatureDescriptor for external types", in: context)
      return nil
    }

    var actionCases: [String: ActionCase] = [:]
    var actionOrder: [String] = []
    for member in action?.memberBlock.members ?? [] {
      guard let cases = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
      for element in cases.elements {
        actionCases[element.name.text] = ActionCase(element: element, attributes: cases.attributes)
        actionOrder.append(element.name.text)
      }
    }

    var snapshots: [String] = []
    var chain: [String] = []
    var consumed: Set<String> = []

    /// Child scopes: a state field (or State case) with a same-named action case.
    func scopedChild(_ name: String, optional: Bool) -> (snapshot: String, child: String)? {
      guard let actionCase = actionCases[name], attribute(actionCase.attributes, "HarnessIgnore") == nil else { return nil }
      let parameters = actionCase.parameters
      if parameters.count == 1, let child = featureType(fromAction: parameters[0].type.trimmedDescription) {
        consumed.insert(name)
        let snapshot = optional ? "state.\(name).map { \(child).harnessDescriptor.snapshot($0) } ?? .null"
          : "\(child).harnessDescriptor.snapshot(state.\(name))"
        return (snapshot, ".child(\(quoted(name)), descriptor: \(child).harnessDescriptor) { $0.scope(\\.\(name)) }")
      }
      if parameters.count == 2, let child = featureType(fromAction: parameters[1].type.trimmedDescription) {
        consumed.insert(name)
        return (".array(state.\(name).prefix(60).map { \(child).harnessDescriptor.snapshot($0) })",
          ".children(\(quoted(name)), descriptor: \(child).harnessDescriptor) { $0.scope(\\.\(name)) }")
      }
      return nil
    }

    if let stateStruct {
      for member in stateStruct.memberBlock.members {
        guard let variable = member.decl.as(VariableDeclSyntax.self),
          !variable.modifiers.contains(where: { ["static", "class"].contains($0.name.text) }) else { continue }
        if attribute(variable.attributes, "HarnessIgnore") != nil { continue }
        let isPrivate = variable.modifiers.contains { ["private", "fileprivate"].contains($0.name.text) }
        let bindingAttribute = attribute(variable.attributes, "HarnessBinding")
        let observed = attribute(variable.attributes, "HarnessObserve") != nil
        for binding in variable.bindings where binding.accessorBlock == nil || observed {
          guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
          let type = binding.typeAnnotation?.type.trimmedDescription
          let initializer = binding.initializer?.value.trimmedDescription
          if let bindingAttribute {
            if variable.bindingSpecifier.text != "var" || isPrivate {
              diagnose(bindingAttribute, "@HarnessBinding requires a non-private 'var'", in: context)
            } else {
              var call = ".binding(\(quoted(name)), label: \(argument(bindingAttribute, nil) ?? quoted("Set \(name)")), \\.\(name)"
              if let available = argument(bindingAttribute, "available") { call += ", available: { $0[keyPath: \(available)] }" }
              chain.append(call + ")")
            }
          }
          if isPrivate { continue }
          if attribute(variable.attributes, "Trigger") != nil { continue }  // Commands, not observable state.
          var snapshot: String
          if sensitive.contains(name.lowercased()) {
            snapshot = ".string(\(quoted("<redacted>")))"
          } else if let (child, shape) = spawned(type: type, initializer: initializer) {
            switch shape {
            case .single:
              snapshot = "\(child).harnessDescriptor.snapshot(state.\(name).state)"
              chain.append(".child(\(quoted(name)), descriptor: \(child).harnessDescriptor) { $0.spawn(\\.\(name)) }")
            case .optional:
              snapshot = "state.\(name).map { \(child).harnessDescriptor.snapshot($0.state) } ?? .null"
              chain.append(".child(\(quoted(name)), descriptor: \(child).harnessDescriptor) { $0.spawn(\\.\(name)) }")
            case .array:
              snapshot = ".array(state.\(name).prefix(60).map { \(child).harnessDescriptor.snapshot($0.state) })"
              chain.append(".children(\(quoted(name)), descriptor: \(child).harnessDescriptor) { $0.spawn(\\.\(name)) }")
            }
          } else {
            let optional = type.map { $0.hasSuffix("?") || $0.hasPrefix("Optional<") } ?? (initializer == "nil")
            if let scoped = scopedChild(name, optional: optional) {
              snapshot = scoped.snapshot
              chain.append(scoped.child)
            } else {
              snapshot = "StateInspection.snapshot(state.\(name) as Any)"
            }
          }
          snapshots.append("\(quoted(name)): \(snapshot)")
        }
      }
    } else if let stateEnum {
      // `@Feature struct Root { enum State { case loggedIn(LoggedIn.State) … } }`.
      for member in stateEnum.memberBlock.members {
        guard let cases = member.decl.as(EnumCaseDeclSyntax.self), attribute(cases.attributes, "HarnessIgnore") == nil else { continue }
        for element in cases.elements {
          let name = element.name.text
          if let parameters = element.parameterClause?.parameters, parameters.count == 1,
            let (child, shape) = spawned(type: parameters.first!.type.trimmedDescription, initializer: nil), shape == .single {
            chain.append(".child(\(quoted(name)), descriptor: \(child).harnessDescriptor) { $0.spawn(\\.\(name)) }")
          } else if let scoped = scopedChild(name, optional: true) {
            chain.append(scoped.child)
          }
        }
      }
    }

    for name in actionOrder where !consumed.contains(name) {
      let actionCase = actionCases[name]!
      let element = actionCase.element
      if attribute(actionCase.attributes, "HarnessIgnore") != nil { continue }
      let operation = attribute(actionCase.attributes, "HarnessOperation")
      let parameters = actionCase.parameters
      let title = argument(operation, nil) ?? quoted(name)
      var options = ""
      if let available = argument(operation, "available") { options += ", available: { $0[keyPath: \(available)] }" }
      if let completion = argument(operation, "completion") { options += ", completion: \(completion)" }
      let choices = argument(operation, "choices")
      func payload(_ index: Int, _ value: String) -> String {
        guard let label = parameters[index].firstName, label.text != "_" else { return value }
        return "\(label.text): \(value)"
      }
      switch parameters.count {
      case 0:
        if choices != nil {
          diagnose(element, "@HarnessOperation(choices:) requires the chosen value as the first payload", in: context)
        } else if operation != nil || name.hasSuffix("Tapped") {
          chain.append(".operation(\(quoted(name)), label: \(title), action: .\(name)\(options))")
        } else {
          diagnose(element, "Action '\(name)' is not exposed; add @HarnessOperation or @HarnessIgnore to declare intent", in: context, severity: .warning)
        }
      case 1 where operation != nil:
        if let choices {
          chain.append(".operation(\(quoted(name)), label: \(title), choices: { $0[keyPath: \(choices)] }, action: { .\(name)(\(payload(0, "$0"))) }\(options))")
        } else {
          let type = parameters[0].type.trimmedDescription
          chain.append(".operation(\(quoted(name)), label: \(title), arguments: \(type).self, action: { .\(name)(\(payload(0, "$0"))) }\(options))")
        }
      case 2 where operation != nil && choices != nil:
        let type = parameters[1].type.trimmedDescription
        chain.append(".operation(\(quoted(name)), label: \(title), choices: { $0[keyPath: \(choices!)] }, arguments: \(type).self, action: { .\(name)(\(payload(0, "$0")), \(payload(1, "$1"))) }\(options))")
      default:
        if operation != nil {
          diagnose(element, "Action '\(name)' has multiple payloads; wrap them in a @HarnessSchema struct, choose the first with 'choices:', or add @HarnessIgnore", in: context)
        } else {
          diagnose(element, "Action '\(name)' is not exposed; add @HarnessOperation with a HarnessInput payload, @HarnessIgnore, or compose an explicit descriptor", in: context, severity: .warning)
        }
      }
    }

    let observation: String
    if stateStruct != nil {
      observation = snapshots.isEmpty ? "{ _ in .object([:]) }"
        : "{ state in\n  .object([\n" + snapshots.map { "    " + $0 }.joined(separator: ",\n") + "\n  ])\n}"
    } else if stateEnum != nil {
      observation = "{ StateInspection.snapshot($0) }"
    } else {
      observation = "{ _ in .object([:]) }"
    }
    return "FeatureDescriptor<State, Action>(\(quoted(feature.name.text)), observation: \(observation))"
      + chain.map { "\n" + $0 }.joined()
  }
}

public struct HarnessSchemaMacro: MemberMacro, ExtensionMacro {
  public static func expansion(of node: AttributeSyntax, providingMembersOf declaration: some DeclGroupSyntax,
    conformingTo protocols: [TypeSyntax], in context: some MacroExpansionContext) throws -> [DeclSyntax] {
    if let enumeration = declaration.as(EnumDeclSyntax.self) {
      guard enumeration.inheritanceClause?.inheritedTypes.contains(where: { $0.type.trimmedDescription == "String" }) == true else {
        diagnose(declaration, "@HarnessSchema enum requires String raw values", in: context); return []
      }
      var choices: [String] = []
      for member in enumeration.memberBlock.members {
        guard let cases = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
        for element in cases.elements {
          guard element.parameterClause == nil else { diagnose(element, "Associated-value enums need an explicit HarnessInput schema", in: context); continue }
          choices.append(element.rawValue?.value.trimmedDescription ?? quoted(element.name.text))
        }
      }
      return ["public static var harnessSchema: HarnessJSONSchema { .string(choices: [\(raw: choices.joined(separator: ", "))]) }"]
    }
    guard let structure = declaration.as(StructDeclSyntax.self) else {
      diagnose(declaration, "@HarnessSchema requires a struct or String enum", in: context); return []
    }
    var fields: [String] = []
    for member in structure.memberBlock.members {
      guard let variable = member.decl.as(VariableDeclSyntax.self), !variable.modifiers.contains(where: { $0.name.text == "static" }) else { continue }
      let field = attribute(variable.attributes, "HarnessField")
      for binding in variable.bindings {
        if binding.accessorBlock != nil { continue }
        guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
          let type = binding.typeAnnotation?.type.trimmedDescription else {
          diagnose(binding, "Schema fields require an explicit type", in: context); continue
        }
        if let field {
          guard type == "String" else { diagnose(field, "@HarnessField applies to String fields", in: context); continue }
          let description = argument(field, nil) ?? "\"\""
          fields.append("\(quoted(name)): .string(description: \(description), minLength: \(argument(field, "minLength") ?? "nil"), maxLength: \(argument(field, "maxLength") ?? "nil"))")
        } else {
          fields.append("\(quoted(name)): (\(type)).harnessSchema")
        }
      }
    }
    let dictionary = fields.isEmpty ? "[:]" : "[\n" + fields.joined(separator: ",\n") + "\n]"
    return ["public static var harnessSchema: HarnessJSONSchema { .object(\(raw: dictionary)) }"]
  }

  public static func expansion(of node: AttributeSyntax, attachedTo declaration: some DeclGroupSyntax,
    providingExtensionsOf type: some TypeSyntaxProtocol, conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext) throws -> [ExtensionDeclSyntax] {
    guard declaration.is(StructDeclSyntax.self) || declaration.is(EnumDeclSyntax.self) else { return [] }
    return [try ExtensionDeclSyntax("extension \(type.trimmed): HarnessInput {}")]
  }
}
