/*
 * generated by Xtext 2.13.0-SNAPSHOT
 */
package io.typefox.yang.validation

import com.google.common.collect.ImmutableList
import com.google.common.collect.LinkedHashMultimap
import com.google.common.collect.Multimap
import com.google.inject.Inject
import com.google.inject.Singleton
import io.typefox.yang.utils.YangExtensions
import io.typefox.yang.utils.YangNameUtils
import io.typefox.yang.utils.YangTypesExtensions
import io.typefox.yang.yang.AbstractModule
import io.typefox.yang.yang.Action
import io.typefox.yang.yang.Anydata
import io.typefox.yang.yang.Anyxml
import io.typefox.yang.yang.Augment
import io.typefox.yang.yang.Base
import io.typefox.yang.yang.Choice
import io.typefox.yang.yang.Container
import io.typefox.yang.yang.Default
import io.typefox.yang.yang.Deviate
import io.typefox.yang.yang.Enum
import io.typefox.yang.yang.FractionDigits
import io.typefox.yang.yang.Identity
import io.typefox.yang.yang.IfFeature
import io.typefox.yang.yang.Import
import io.typefox.yang.yang.Include
import io.typefox.yang.yang.Key
import io.typefox.yang.yang.Leaf
import io.typefox.yang.yang.LeafList
import io.typefox.yang.yang.List
import io.typefox.yang.yang.Mandatory
import io.typefox.yang.yang.MaxElements
import io.typefox.yang.yang.MinElements
import io.typefox.yang.yang.Modifier
import io.typefox.yang.yang.Notification
import io.typefox.yang.yang.OrderedBy
import io.typefox.yang.yang.Pattern
import io.typefox.yang.yang.Presence
import io.typefox.yang.yang.Refinable
import io.typefox.yang.yang.Revision
import io.typefox.yang.yang.Rpc
import io.typefox.yang.yang.SchemaNode
import io.typefox.yang.yang.SchemaNodeIdentifier
import io.typefox.yang.yang.Statement
import io.typefox.yang.yang.Status
import io.typefox.yang.yang.Type
import io.typefox.yang.yang.Typedef
import io.typefox.yang.yang.YangVersion
import java.util.Collection
import org.eclipse.emf.ecore.EClass
import org.eclipse.emf.ecore.EStructuralFeature
import org.eclipse.emf.ecore.xml.type.internal.RegEx.ParseException
import org.eclipse.emf.ecore.xml.type.internal.RegEx.RegularExpression
import org.eclipse.xtext.naming.IQualifiedNameProvider
import org.eclipse.xtext.nodemodel.util.NodeModelUtils
import org.eclipse.xtext.scoping.IScopeProvider
import org.eclipse.xtext.validation.Check

import static com.google.common.base.CharMatcher.*
import static io.typefox.yang.utils.YangExtensions.*
import static io.typefox.yang.validation.IssueCodes.*
import static io.typefox.yang.yang.YangPackage.Literals.*

import static extension com.google.common.base.Strings.nullToEmpty
import static extension io.typefox.yang.utils.IterableExtensions2.*
import static extension io.typefox.yang.utils.YangDateUtils.*
import static extension io.typefox.yang.utils.YangNameUtils.*

/**
 * This class contains custom validation rules for the YANG language. 
 */
@Singleton
class YangValidator extends AbstractYangValidator {

	@Inject
	extension YangExtensions;

	@Inject
	extension YangTypesExtensions;

	@Inject
	extension YangEnumerableValidator;

	@Inject
	IQualifiedNameProvider qualifiedNameProvider;

	@Inject
	IScopeProvider scopeProvider;

	@Inject
	SubstatementRuleProvider substatementRuleProvider;

	val Multimap<EClass, EClass> validAugmentStatements;
	val Collection<EClass> validShorthandStatements;

	new() {
		super();
		// https://tools.ietf.org/html/rfc7950#section-7.17
		// The following map contain the valid sub-statements based on the type of the augmented node.
		validAugmentStatements = LinkedHashMultimap.create;
		#[CONTAINER, LIST, CASE, INPUT, OUTPUT, NOTIFICATION].forEach [
			validAugmentStatements.putAll(it, #[CONTAINER, LEAF, LIST, LEAF_LIST, USES, CHOICE]);
			if (it === CONTAINER || it === LIST) {
				validAugmentStatements.putAll(it, #[ACTION, NOTIFICATION])
			}
		];
		validAugmentStatements.put(CHOICE, CASE);
		// https://tools.ietf.org/html/rfc7950#section-7.9.2
		// Shorthand "case" statement. 
		validShorthandStatements = ImmutableList.copyOf(#[ANYDATA, ANYXML, CHOICE, CONTAINER, LEAF, LIST, LEAF_LIST]);
	}

	@Check
	def void checkVersion(YangVersion it) {
		if (yangVersion != YANG_1 && yangVersion != YANG_1_1) {
			val message = '''The version must be either "«YANG_1»" or "«YANG_1_1»".''';
			error(message, it, YANG_VERSION__YANG_VERSION, INCORRECT_VERSION);
		}
	}

	@Check
	def void checkVersionConsistency(AbstractModule it) {
		// https://tools.ietf.org/html/rfc7950#section-12
		// A YANG version 1.1 module must not include a YANG version 1 submodule, and a YANG version 1 module must not include a YANG version 1.1 submodule.
		val moduleVersion = yangVersion;
		substatementsOfType(Include).map[module].filterNull.filter[eResource !== null && !eIsProxy].filter [
			yangVersion != moduleVersion
		].forEach [
			val message = '''Cannot include a version «yangVersion» submodule in a version «moduleVersion» module.''';
			error(message, it, ABSTRACT_IMPORT__MODULE, BAD_INCLUDE_YANG_VERSION);
		];

		// A YANG version 1 module or submodule must not import a YANG version 1.1 module by revision.	
		if (moduleVersion == YANG_1) {
			substatementsOfType(Import).map[module].filterNull.filter[eResource !== null && !eIsProxy].filter [
				yangVersion != moduleVersion
			].forEach [
				val message = '''Cannot import a version «yangVersion» submodule in a version «moduleVersion» module.''';
				error(message, it, ABSTRACT_IMPORT__MODULE, BAD_IMPORT_YANG_VERSION);
			];
		}
	}

	@Check
	def void checkSubstatements(Statement it) {
		substatementRuleProvider.get(eClass)?.checkSubstatements(it, this);
	}

	@Check
	def void checkTypeRestriction(Type it) {
		// https://tools.ietf.org/html/rfc7950#section-9.2.3
		// https://tools.ietf.org/html/rfc7950#section-9.3.3
		// Same for string it just has another statement name.
		// https://tools.ietf.org/html/rfc7950#section-9.4.3
		val refinements = substatementsOfType(Refinable);
		if (!refinements.nullOrEmpty) {
			val expectedRefinementKind = refinementKind;
			refinements.forEach [
				if (expectedRefinementKind === null || !(expectedRefinementKind.isAssignableFrom(it.class))) {
					val message = '''Type cannot have "«YangNameUtils.getYangName(it.eClass)»" restriction statement.''';
					error(message, it, REFINABLE__EXPRESSION, TYPE_ERROR);
				}
			];
		}
	}

	@Check
	def checkRefinement(Refinable it) {
		val yangRefinable = yangRefinable;
		if (yangRefinable !== null) {
			yangRefinable.validate(this);
		}
	}

	@Check
	def checkUnionType(Type it) {
		if (union) {
			// At least one `type` sub-statement should be present for each `union` type.
			// https://tools.ietf.org/html/rfc7950#section-9.12
			if (substatementsOfType(Type).nullOrEmpty) {
				val message = '''Type substatement must be present for each union type.''';
				error(message, it, TYPE__TYPE_REF, TYPE_ERROR);
			}
		}
	}

	@Check
	def checkIdentityrefType(Type it) {
		if (identityref) {
			// The "base" statement, which is a sub-statement to the "type" statement, 
			// must be present at least once if the type is "identityref".
			// https://tools.ietf.org/html/rfc7950#section-9.10.2
			if (substatementsOfType(Base).nullOrEmpty) {
				val message = '''The "base" statement must be present at least once for all "identityref" types''';
				error(message, it, TYPE__TYPE_REF, TYPE_ERROR);
			}
		}
	}

	@Check
	def checkEnumerables(Type it) {
		validateEnumerable(this);
	}

	@Check
	def checkEnumeration(Type type) {
		val enums = type.substatementsOfType(Enum);
		if (!type.subtypeOfEnumeration) {
			enums.forEach [
				val message = '''Only enumeration types can have a "enum" statement.''';
				error(message, type, TYPE__TYPE_REF, TYPE_ERROR);
			];
		} else {
			enums.forEach [
				val message = if (name.length === 0) {
						'''The name must not be zero-length.'''
					} else if (name != WHITESPACE.or(BREAKING_WHITESPACE).trimFrom(name)) {
						'''The name must not have any leading or trailing whitespace characters.'''
					} else {
						null;
					}
				if (message !== null) {
					error(message, it, ENUMERABLE__NAME, TYPE_ERROR);
				}
			];
		}
	}

	@Check
	def checkFractionDigitsExist(Type it) {
		// https://tools.ietf.org/html/rfc7950#section-9.3.4
		val fractionDigits = firstSubstatementsOfType(FractionDigits);
		val fractionDigitsExist = fractionDigits !== null;
		// Note, only the decimal type definition MUST have the `fraction-digits` statement.
		// It is not mandatory for types that are derived from decimal built-ins. 
		val decimalBuiltin = decimal;
		if (decimalBuiltin) {
			if (fractionDigitsExist) {
				// Validate the fraction digits. It takes as an argument an integer between 1 and 18, inclusively.
				val value = fractionDigitsAsInt;
				if (value.intValue < 1 || value.intValue > 18) {
					val message = '''The "fraction-digits" value must be an integer between 1 and 18, inclusively.''';
					error(message, fractionDigits, FRACTION_DIGITS__RANGE, TYPE_ERROR);
				}

			} else {
				// Decimal types must have fraction-digits sub-statement.
				val message = '''The "fraction-digits" statement must be present for "decimal64" types.''';
				error(message, it, TYPE__TYPE_REF, TYPE_ERROR);
			}
		} else {
			if (fractionDigitsExist) {
				val message = '''Only decimal64 types can have a "fraction-digits" statement.''';
				error(message, it, TYPE__TYPE_REF, TYPE_ERROR);
			}
		}
	}

	@Check
	def checkPattern(Pattern it) {
		// https://tools.ietf.org/html/rfc7950#section-9.4.5
		if (eContainer instanceof Type) {
			val type = eContainer as Type;
			if (type.subtypeOfString) {
				try {
					new RegularExpression(regexp.nullToEmpty, 'X');
				} catch (ParseException e) {
					val message = if (regexp.nullOrEmpty) {
							'Regular expression must be specified.'
						} else {
							'''Invalid regular expression pattern: "«regexp»".''';
						}
					error(message, it, PATTERN__REGEXP, TYPE_ERROR);
				}
			} else {
				val message = '''Only string types can have a "pattern" statement.''';
				error(message, type, TYPE__TYPE_REF, TYPE_ERROR);
			}
		}
	}

	@Check
	def checkModifier(Modifier it) {
		// https://tools.ietf.org/html/rfc7950#section-9.4.6
		if (modifier != 'invert-match') {
			val message = '''Modifier value must be "invert-match".''';
			error(message, it, MODIFIER__MODIFIER, TYPE_ERROR);
		}
	}

	@Check
	def checkRevisionFormat(Revision it) {
		if (revision !== null) {
			try {
				revisionDateFormat.parse(revision);
			} catch (java.text.ParseException e) {
				val message = '''The revision date string should be in the following format: "YYYY-MM-DD".''';
				warning(message, it, REVISION__REVISION, INVALID_REVISION_FORMAT);
			}
		}
	}

	@Check
	def checkRevisionOrder(AbstractModule it) {
		val revisions = substatementsOfType(Revision).toList;
		for (index : 1 ..< revisions.size) {
			val previous = revisions.get(index - 1);
			val current = revisions.get(index);
			if (current.isGreaterThan(previous)) {
				val message = '''The revision statement is not given in reverse chronological order.''';
				warning(message, current, REVISION__REVISION, REVISION_ORDER);
			}
		}
	}

	@Check
	def checkTypedef(Typedef it) {
		// The [1..*] type cardinality is checked by other rules.
		// Also, the type name uniqueness is checked in the scoping. 
		// https://tools.ietf.org/html/rfc7950#section-7.3
		if (name.builtinName) {
			val message = '''Illegal type name "«name»".''';
			error(message, it, SCHEMA_NODE__NAME, BAD_TYPE_NAME);
		}
	}

	@Check
	def checkMandatoryValue(Mandatory it) {
		// https://tools.ietf.org/html/rfc7950#section-7.6.5
		// The value can be either `true` or `false`. If missing, then `false` by default.
		if (isMandatory !== null) {
			val validValues = #{"true", "false"};
			if (!validValues.contains(isMandatory)) {
				val message = '''The argument of the "mandatory" statement must be either "true" or "false".''';
				error(message, it, MANDATORY__IS_MANDATORY, TYPE_ERROR);
			}
		}
	}

	@Check
	def checkMinElements(MinElements it) {
		// https://tools.ietf.org/html/rfc7950#section-7.7.5
		val expectedElements = minElements.parseIntSafe;
		if (expectedElements === null || expectedElements.intValue < 0) {
			val message = '''The value of the "min-elements" must be a non-negative integer.''';
			error(message, it, MIN_ELEMENTS__MIN_ELEMENTS, TYPE_ERROR);
		}
	}

	@Check
	def chechMaxElements(MaxElements it) {
		// https://tools.ietf.org/html/rfc7950#section-7.7.6
		if (maxElements != 'unbounded') {
			val expectedElements = maxElements.parseIntSafe;
			if (expectedElements === null || expectedElements.intValue < 1) {
				val message = '''The value of the "max-elements" must be a positive integer or the string "unbounded".''';
				error(message, it, MIN_ELEMENTS__MIN_ELEMENTS, TYPE_ERROR);
			}
		}
	}

	@Check
	def checkOrderedBy(OrderedBy it) {
		// https://tools.ietf.org/html/rfc7950#section-7.7.7
		if (orderedBy !== null) {
			val validValues = #{"system", "user"};
			if (!validValues.contains(orderedBy)) {
				val message = '''The argument of the "ordered-by" statement must be either "system" or "user".''';
				error(message, it, ORDERED_BY__ORDERED_BY, TYPE_ERROR);
			}
		}
	}

	@Check
	def checkKey(Key key) {
		// https://tools.ietf.org/html/rfc7950#section-7.8.2	
		// A leaf identifier must not appear more than once in the key.
		key.references.filter[!node?.name.nullOrEmpty].toMultimap[node.name].asMap.forEach [ name, nodesWithSameName |
			if (nodesWithSameName.size > 1) {
				nodesWithSameName.forEach [
					val message = '''The leaf identifier "«name»" must not appear more than once in a key.''';
					val index = key.references.indexOf(it);
					error(message, key, KEY__REFERENCES, index, KEY_DUPLICATE_LEAF_NAME);
				];
			}
		];
		// https://tools.ietf.org/html/rfc7950#section-7.20.2
		// A leaf that is a list key must not have any "if-feature" statements.
		key.references.map[it -> node].filterNull.forEach [ pair |
			if (pair.value.firstSubstatementsOfType(IfFeature) !== null) {
				val message = '''A leaf that is a list key must not have any "if-feature" statements.''';
				error(message, pair.key, KEY_REFERENCE__NODE, LEAF_KEY_WITH_IF_FEATURE);
			}
		];
	}

	@Check
	def checkDeviate(Deviate it) {
		// https://tools.ietf.org/html/rfc7950#section-7.20.3.2
		// The argument is one of the strings "not-supported", "add", "replace", or "delete".
		val argument = argument;
		if (!argument.nullOrEmpty) {
			val validArguments = #{"not-supported", "add", "replace", "delete"};
			if (!validArguments.contains(argument)) {
				val message = '''The argument of the "deviate" statement must be «validArguments.toPrettyString('or')».''';
				error(message, it, DEVIATE__ARGUMENT, TYPE_ERROR);
			}
		}
	}

	@Check
	def checkStatus(Status it) {
		// https://tools.ietf.org/html/rfc7950#section-7.21.2
		// The "status" statement takes as an argument one of the strings "current", "deprecated", or "obsolete".
		val status = argument;
		if (!argument.nullOrEmpty) {
			val validArguments = #{"current", "deprecated", "obsolete"};
			if (!validArguments.contains(status)) {
				val message = '''The argument of the "status" statement must be «validArguments.toPrettyString('or')».''';
				error(message, it, STATUS__ARGUMENT, TYPE_ERROR);
			}
		}
	}

	@Check
	def checkAugment(Augment it) {
		// https://tools.ietf.org/html/rfc7950#section-7.17
		// (1) The target node MUST be either a container, list, choice, case, input,
		// output, or notification node.
		// (2) If the target node is a container, list, case, input, output, or
		// notification node, the "container", "leaf", "list", "leaf-list",
		// "uses", and "choice" statements can be used within the "augment" statement.
		// (3) If the target node is a container or list node, the "action" and
		// "notification" statements can be used within the "augment" statement.
		// (4) If the target node is a choice node, the "case" statement or a
		// shorthand "case" statement (see Section 7.9.2) can be used within the "augment" statement.
		val target = path?.schemaNode;
		if (target !== null) {
			val validSubstatements = validAugmentStatements.get(target.eClass);
			if (validSubstatements.nullOrEmpty) {
				// Implicit `input` and `output` is added to all "rpc" and "action" statements. (See: RFC 7950 7.14)
				// ScopeContextProvider.getQualifiedName(SchemaNode, QualifiedName, IScopeContext)
				if (target.eClass === RPC || target.eClass === ACTION) {
					val lastSegment = path.lastPathSegment;
					if (lastSegment == 'input' || lastSegment == 'output') {
						val fqn = qualifiedNameProvider.getFullyQualifiedName(target);
						if (fqn !== null) {
							val scope = scopeProvider.getScope(target, STATEMENT__SUBSTATEMENTS);
							val inputOrOutputFqn = fqn.append(target.mainModule.name).append(lastSegment);
							if (scope.getSingleElement(inputOrOutputFqn) !== null) {
								return;
							}
						}
					}
				}
				val validTypes = validAugmentStatements.keySet.map[yangName].toPrettyString('or');
				val message = '''The augment's target node must be either a «validTypes» node.''';
				error(message, it, AUGMENT__PATH, INVALID_AUGMENTATION);
			} else {
				// As a shorthand, the "case" statement can be omitted if the branch contains a single "anydata", "anyxml", 
				// "choice", "container", "leaf", "list", or "leaf-list" statement.
				val schemaNodes = substatements.filter(SchemaNode);
				if (target.eClass === CHOICE && schemaNodes.size === 1) {
					if (!validShorthandStatements.contains(schemaNodes.head.eClass) &&
						schemaNodes.head.eClass !== CASE) {
						val message = '''If the target node is a "choice" node, the "case" statement or a shorthand "case" statement can be used within the "augment" statement.''';
						error(message, schemaNodes.head, SCHEMA_NODE__NAME, INVALID_AUGMENTATION);
					}
				} else {
					schemaNodes.forEach [
						if (!validSubstatements.contains(eClass)) {
							val validTypes = validSubstatements.map[yangName].toPrettyString('or');
							val message = '''If the target node is a "«target.eClass.yangName»" node, a «validTypes» statements can be used within the "augment" statement.''';
							error(message, it, SCHEMA_NODE__NAME, INVALID_AUGMENTATION);
						}
					];
				}
			}
		}
		// The "augment" statement must not add multiple nodes with the same name from the same module to the target node.
		// https://tools.ietf.org/html/rfc7950#section-7.17
		// Done by the scoping.
	}

	@Check
	def void checkAction(Action it) {
		// https://tools.ietf.org/html/rfc7950#section-7.15
		// An action must not have any ancestor node that is a list node without a "key" statement.
		// An action must not be defined within an rpc, another action, or a notification, i.e., an action node must 
		// not have an rpc, action, or a notification node as one of its ancestors in the schema tree.
		checkAncestors(ACTION__NAME);
	}

	@Check
	def void checkNotification(Notification it) {
		// https://tools.ietf.org/html/rfc7950#section-7.16
		// A notification must not have any ancestor node that is a list node without a "key" statement.
		// A notification must not be defined within an rpc, another action, or a notification, i.e., a notification node must 
		// not have an rpc, action, or a notification node as one of its ancestors in the schema tree.
		checkAncestors(SCHEMA_NODE__NAME);
	}

	private def checkAncestors(Statement it, EStructuralFeature feature) {
		val name = yangName;
		var ancestor = eContainer;
		while (ancestor instanceof Statement) {
			if (ancestor instanceof List) {
				if (ancestor.firstSubstatementsOfType(Key) === null) {
					val message = '''"«name»" node must not have any ancestor node that is a list node without a "key" statement.''';
					error(message, it, feature, INVALID_ANCESTOR);
				}
			} else if (ancestor instanceof Action || ancestor instanceof Rpc || ancestor instanceof Notification) {
				val message = '''"«name»" node must not be defined within a "«ancestor.yangName»" statement.''';
				error(message, it, feature, INVALID_ANCESTOR);
			}
			ancestor = ancestor.eContainer;
		}
	}

	@Check
	def void checkIdentity(Identity it) {
		// https://tools.ietf.org/html/rfc7950#section-7.18.2
		// An identity must not reference itself, neither directly nor indirectly through a chain of other identities.
		val (Identity)=>Identity getBase = [firstSubstatementsOfType(Base)?.reference];
		var base = getBase.apply(it);
		while (base !== null) {
			if (it == base) {
				val message = '''An identity must not reference itself, neither directly nor indirectly through a chain of other identities.''';
				error(message, it, SCHEMA_NODE__NAME, IDENTITY_CYCLE);
			}
			base = getBase.apply(base);
		}
	}

	@Check
	def void checkDefault(Choice it) {
		// https://tools.ietf.org/html/rfc7950#section-7.9.3
		// The "default" statement must not be present on choices where "mandatory" is "true".
		val ^default = firstSubstatementsOfType(Default);
		if (^default !== null) {
			val mandatory = firstSubstatementsOfType(Mandatory);
			if ('true' == mandatory?.isMandatory) {
				val message = '''The "default" statement must not be present on choices where "mandatory" is "true"''';
				error(message, it, SCHEMA_NODE__NAME, INVALID_DEFAULT);
			}
			// There must not be any mandatory nodes (Terminology: https://tools.ietf.org/html/rfc7950#section-3) directly under the default case.
			val substatements = substatements;
			val length = substatements.length;
			val index = substatements.indexOf(^default);
			if (index > 0 && index < length - 1) {
				for (var i = index; i < length; i++) {
					val statement = substatements.get(i);
					if (statement.mandatory) {
						val message = '''There must not be any mandatory nodes directly under the default case.''';
						error(message, statement, null, MANDATORY_AFTER_DEFAULT_CASE);
					}
				}
			}
		}

	}

	/**
	 * Returns {@code true} if the argument is a mandatory node, otherwise {@code false}.
	 * A mandatory node is one of:
	 * <ul>
	 * <li>A leaf, choice, anydata, or anyxml node with a "mandatory" statement with the value "true".</li>
	 * <li>A list or leaf-list node with a "min-elements" statement with a value greater than zero.</li>
	 * <li>A container node without a "presence" statement and that has at least one mandatory node as a child.</li>
	 * </ul>
	 * See: https://tools.ietf.org/html/rfc7950#section-3
	 */
	private dispatch def boolean isMandatory(Statement it) {
		return false;
	}

	private dispatch def boolean isMandatory(Leaf it) {
		return firstSubstatementsOfType(Mandatory).mandatory;
	}

	private dispatch def boolean isMandatory(Choice it) {
		return firstSubstatementsOfType(Mandatory).mandatory;
	}

	private dispatch def boolean isMandatory(Anydata it) {
		return firstSubstatementsOfType(Mandatory).mandatory;
	}

	private dispatch def boolean isMandatory(Anyxml it) {
		return firstSubstatementsOfType(Mandatory).mandatory;
	}

	private dispatch def boolean isMandatory(List it) {
		return firstSubstatementsOfType(MinElements).mandatory;
	}

	private dispatch def boolean isMandatory(LeafList it) {
		return firstSubstatementsOfType(MinElements).mandatory;
	}

	private dispatch def boolean isMandatory(Container it) {
		return substatementsOfType(Presence).nullOrEmpty && substatements.exists[mandatory];
	}

	private dispatch def boolean isMandatory(MinElements it) {
		val value = minElements.parseIntSafe;
		return value !== null && value.intValue > 0;
	}

	private dispatch def boolean isMandatory(Mandatory it) {
		return 'true' == isMandatory;
	}

	private dispatch def boolean isMandatory(Void it) {
		return false;
	}

	/**
	 * Returns with the text of the last non-hidden leaf node of the argument, or {@code null}.
	 */
	private def getLastPathSegment(SchemaNodeIdentifier it) {
		val node = NodeModelUtils.findActualNodeFor(it);
		if (node !== null) {
			val itr = node.leafNodes.toList.reverse.iterator;
			while (itr.hasNext) {
				val leafNode = itr.next;
				if (!leafNode.hidden) {
					return leafNode.text;
				}
			}
		}
		return null;
	}

	private def getParseIntSafe(String it) {
		return try {
			if(nullOrEmpty) null else Integer.parseInt(it);
		} catch (NumberFormatException e) {
			null;
		}
	}

}
