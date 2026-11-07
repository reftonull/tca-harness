import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

private struct HarnessDiagnostic: DiagnosticMessage {
  let message: String
  var diagnosticID: MessageID { MessageID(domain: "TCAHarness", id: "unsupported") }
  let severity: DiagnosticSeverity
}
private func diagnose(_ node: some SyntaxProtocol, _ message: String, in context: some MacroExpansionContext, severity: DiagnosticSeverity = .error) {
  context.diagnose(Diagnostic(node: Syntax(node), message: HarnessDiagnostic(message: message, severity: severity)))
}
private func has(_ attributes: AttributeListSyntax, _ name: String) -> Bool {
  attributes.contains { $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription.split(separator: ".").last == Substring(name) }
}
private func label(_ attributes: AttributeListSyntax, fallback: String) -> String {
  for element in attributes {
    guard let attribute = element.as(AttributeSyntax.self), attribute.attributeName.trimmedDescription == "HarnessOperation",
      case let .argumentList(arguments) = attribute.arguments,
      let expression = arguments.first?.expression else { continue }
    return expression.trimmedDescription
  }
  return String(reflecting: fallback)
}

public struct MarkerMacro: PeerMacro {
  public static func expansion(of node: AttributeSyntax, providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext) throws -> [DeclSyntax] { [] }
}

public struct HarnessFeatureMacro: MemberMacro, ExtensionMacro {
  public static func expansion(of node: AttributeSyntax, attachedTo declaration: some DeclGroupSyntax,
    providingExtensionsOf type: some TypeSyntaxProtocol, conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext) throws -> [ExtensionDeclSyntax] {
    guard let feature = declaration.as(StructDeclSyntax.self),
      feature.memberBlock.members.contains(where: { $0.decl.as(StructDeclSyntax.self)?.name.text == "State" }),
      feature.memberBlock.members.contains(where: { $0.decl.as(EnumDeclSyntax.self)?.name.text == "Action" }) else { return [] }
    return [try ExtensionDeclSyntax("extension \(type): HarnessFeatureProvider {}")]
  }

  public static func expansion(of node: AttributeSyntax, providingMembersOf declaration: some DeclGroupSyntax,
    conformingTo protocols: [TypeSyntax], in context: some MacroExpansionContext) throws -> [DeclSyntax] {
    guard let feature = declaration.as(StructDeclSyntax.self),
      let state = feature.memberBlock.members.compactMap({ $0.decl.as(StructDeclSyntax.self) }).first(where: { $0.name.text == "State" }),
      let action = feature.memberBlock.members.compactMap({ $0.decl.as(EnumDeclSyntax.self) }).first(where: { $0.name.text == "Action" }) else {
      diagnose(declaration, "@HarnessFeature requires a struct with locally declared State and Action; use an explicit FeatureDescriptor for external types", in: context)
      return []
    }
    var childSnapshots: [String: (String, String)] = [:]
    for member in action.memberBlock.members {
      guard let cases = member.decl.as(EnumCaseDeclSyntax.self), !has(cases.attributes, "HarnessIgnore"), !has(cases.attributes, "HarnessOperation") else { continue }
      for element in cases.elements {
        guard let parameters = element.parameterClause?.parameters, parameters.count == 1, let parameter = parameters.first else { continue }
        let type = parameter.type.trimmedDescription
        if type.hasSuffix(".Action") {
          childSnapshots[element.name.text] = (String(type.dropLast(".Action".count)), "single")
        } else if type.hasPrefix("PresentationAction<"), type.hasSuffix(".Action>") {
          childSnapshots[element.name.text] = (String(type.dropFirst("PresentationAction<".count).dropLast(".Action>".count)), "optional")
        } else {
          for prefix in ["IdentifiedActionOf<", "StackActionOf<"] where type.hasPrefix(prefix) && type.hasSuffix(">") {
            childSnapshots[element.name.text] = (String(type.dropFirst(prefix.count).dropLast()), "collection")
          }
        }
      }
    }
    var observed: [String] = []
    let sensitive: Set<String> = ["token", "accesstoken", "refreshtoken", "password", "apikey", "authorization"]
    for member in state.memberBlock.members {
      guard let variable = member.decl.as(VariableDeclSyntax.self), !has(variable.attributes, "HarnessIgnore"),
        !variable.modifiers.contains(where: { ["static", "class", "private"].contains($0.name.text) }) else { continue }
      for binding in variable.bindings where binding.accessorBlock == nil {
        guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
        var value = sensitive.contains(name.lowercased()) ? ".string(\(String(reflecting: "<redacted>")))" : "StateInspection.snapshot(state.\(name))"
        if let (child, kind) = childSnapshots[name], binding.typeAnnotation != nil {
          if kind == "collection" { value = ".array(state.\(name).prefix(60).map { \(child).harnessDescriptor.snapshot($0) })" }
          else if kind == "optional" || binding.typeAnnotation!.type.trimmedDescription.hasSuffix("?") {
            value = "state.\(name).map { \(child).harnessDescriptor.snapshot($0) } ?? .null"
          } else { value = "\(child).harnessDescriptor.snapshot(state.\(name))" }
        }
        observed.append("\(String(reflecting: name)): \(value)")
      }
    }
    let projection = observed.isEmpty ? "[:]" : "[" + observed.joined(separator: ", ") + "]"
    var expression = "FeatureDescriptor<State, Action>(\(String(reflecting: feature.name.text)), observation: { state in .object(\(projection)) })"
    let properties = Dictionary(state.memberBlock.members.compactMap { member -> (String, String)? in
      guard let variable = member.decl.as(VariableDeclSyntax.self), !has(variable.attributes, "HarnessIgnore"),
        let binding = variable.bindings.first, let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
        let type = binding.typeAnnotation?.type.trimmedDescription else { return nil }
      return (name, type)
    }, uniquingKeysWith: { first, _ in first })

    // Every case that doesn't become an operation or a child scope, and why; `tca exposure` reports them.
    var unexposed: [(action: String, reason: String)] = []
    for member in action.memberBlock.members {
      guard let cases = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
      if has(cases.attributes, "HarnessIgnore") {
        unexposed += cases.elements.map { ($0.name.text, "ignored") }
        continue
      }
      let exposed = has(cases.attributes, "HarnessOperation")
      for element in cases.elements {
        let name = element.name.text
        let parameters = element.parameterClause?.parameters
        let title = label(cases.attributes, fallback: name)
        if parameters == nil || parameters!.isEmpty {
          if exposed || name.hasSuffix("ButtonTapped") {
            expression += "\n.operation(\(String(reflecting: name)), label: \(title), action: .\(name))"
          } else {
            diagnose(element, "Action '\(name)' is not exposed; add @HarnessOperation or @HarnessIgnore to declare intent", in: context, severity: .warning)
            unexposed.append((name, "unannotated"))
          }
          continue
        }
        guard let parameters, parameters.count == 1, let parameter = parameters.first else {
          diagnose(element, "Action '\(name)' has multiple payloads; wrap them in a @HarnessSchema struct or add @HarnessIgnore", in: context, severity: exposed ? .error : .warning)
          if !exposed { unexposed.append((name, "multiple payloads")) }
          continue
        }
        let type = parameter.type.trimmedDescription
        let argument = parameter.firstName.map { $0.text == "_" ? "$0" : "\($0.text): $0" } ?? "$0"
        if exposed {
          let primitive = ["String", "Int", "Bool", "Double", "Float"].contains(type)
          expression += primitive
            ? "\n.valueOperation(\(String(reflecting: name)), label: \(title), value: \(type).self, action: { .\(name)(\(argument)) })"
            : "\n.operation(\(String(reflecting: name)), label: \(title), arguments: \(type).self, action: { .\(name)(\(argument)) })"
          continue
        }
        if type == "BindingAction<State>" { unexposed.append((name, "binding")); continue }
        if type.hasSuffix(".Action"), let field = properties[name] {
          let child = String(type.dropLast(".Action".count))
          let method = field.hasSuffix("?") ? "optional" : "child"
          expression += "\n.\(method)(\(String(reflecting: name)), state: \\.\(name), action: \\.\(name), descriptor: \(child).harnessDescriptor)"
        } else if type.hasPrefix("PresentationAction<"), type.hasSuffix(".Action>"), properties[name] != nil {
          let child = String(type.dropFirst("PresentationAction<".count).dropLast(".Action>".count))
          expression += "\n.presentation(\(String(reflecting: name)), state: \\.\(name), action: \\.\(name), descriptor: \(child).harnessDescriptor)"
        } else if type.hasPrefix("IdentifiedActionOf<"), type.hasSuffix(">"), properties[name] != nil {
          let child = String(type.dropFirst("IdentifiedActionOf<".count).dropLast())
          expression += "\n.identified(\(String(reflecting: name)), state: \\.\(name), action: \\.\(name), descriptor: \(child).harnessDescriptor)"
        } else if type.hasPrefix("StackActionOf<"), type.hasSuffix(">"), properties[name] != nil {
          let child = String(type.dropFirst("StackActionOf<".count).dropLast())
          expression += "\n.stack(\(String(reflecting: name)), state: \\.\(name), action: \\.\(name), descriptor: \(child).harnessDescriptor)"
        } else {
          diagnose(element, "Cannot derive action '\(name)'; add @HarnessOperation with a HarnessInput payload, @HarnessIgnore, or compose an explicit descriptor", in: context, severity: .warning)
          unexposed.append((name, "unsupported payload"))
        }
      }
    }
    for (name, reason) in unexposed {
      expression += "\n.unexposed(\(String(reflecting: name)), reason: \(String(reflecting: reason)))"
    }
    // `customizeHarnessDescriptor` defaults to identity; features override it to add invariants.
    return [DeclSyntax(stringLiteral: "@MainActor public static var harnessDescriptor: FeatureDescriptor<State, Action> {\ncustomizeHarnessDescriptor(\n\(expression)\n)\n}")]
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
          choices.append(element.rawValue?.value.trimmedDescription ?? String(reflecting: element.name.text))
        }
      }
      return [DeclSyntax(stringLiteral: "public static var harnessSchema: HarnessJSONSchema { .string(choices: [\(choices.joined(separator: ", "))]) }")]
    }
    guard let structure = declaration.as(StructDeclSyntax.self) else {
      diagnose(declaration, "@HarnessSchema requires a struct or String enum", in: context); return []
    }
    var fields: [String] = []
    for member in structure.memberBlock.members {
      guard let variable = member.decl.as(VariableDeclSyntax.self), !variable.modifiers.contains(where: { $0.name.text == "static" }) else { continue }
      for binding in variable.bindings {
        if binding.accessorBlock != nil { continue }
        guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
          let type = binding.typeAnnotation?.type.trimmedDescription else {
          diagnose(binding, "Schema fields require an explicit type", in: context); continue
        }
        fields.append("\(String(reflecting: name)): (\(type)).harnessSchema")
      }
    }
    let dictionary = fields.isEmpty ? "[:]" : "[\n" + fields.joined(separator: ",\n") + "\n]"
    return [DeclSyntax(stringLiteral: "public static var harnessSchema: HarnessJSONSchema { .object(\(dictionary)) }")]
  }

  public static func expansion(of node: AttributeSyntax, attachedTo declaration: some DeclGroupSyntax,
    providingExtensionsOf type: some TypeSyntaxProtocol, conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext) throws -> [ExtensionDeclSyntax] {
    guard declaration.is(StructDeclSyntax.self) || declaration.is(EnumDeclSyntax.self) else { return [] }
    return [try ExtensionDeclSyntax("extension \(type): HarnessInput {}")]
  }
}
