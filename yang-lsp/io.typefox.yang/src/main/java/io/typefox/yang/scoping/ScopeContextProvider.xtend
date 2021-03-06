package io.typefox.yang.scoping

import com.google.common.collect.LinkedHashMultimap
import com.google.inject.Inject
import io.typefox.yang.scoping.ScopeContext.MapScope
import io.typefox.yang.scoping.xpath.XpathResolver
import io.typefox.yang.utils.YangExtensions
import io.typefox.yang.utils.YangPathProvider
import io.typefox.yang.validation.IssueCodes
import io.typefox.yang.yang.AbstractImport
import io.typefox.yang.yang.AbstractModule
import io.typefox.yang.yang.Action
import io.typefox.yang.yang.Augment
import io.typefox.yang.yang.Base
import io.typefox.yang.yang.BelongsTo
import io.typefox.yang.yang.Case
import io.typefox.yang.yang.Choice
import io.typefox.yang.yang.Config
import io.typefox.yang.yang.Deviation
import io.typefox.yang.yang.Extension
import io.typefox.yang.yang.Feature
import io.typefox.yang.yang.FeatureReference
import io.typefox.yang.yang.Grouping
import io.typefox.yang.yang.GroupingRef
import io.typefox.yang.yang.Identity
import io.typefox.yang.yang.Import
import io.typefox.yang.yang.Include
import io.typefox.yang.yang.Input
import io.typefox.yang.yang.KeyReference
import io.typefox.yang.yang.Module
import io.typefox.yang.yang.Must
import io.typefox.yang.yang.Output
import io.typefox.yang.yang.Path
import io.typefox.yang.yang.Refine
import io.typefox.yang.yang.Revision
import io.typefox.yang.yang.RevisionDate
import io.typefox.yang.yang.Rpc
import io.typefox.yang.yang.SchemaNode
import io.typefox.yang.yang.SchemaNodeIdentifier
import io.typefox.yang.yang.Statement
import io.typefox.yang.yang.Submodule
import io.typefox.yang.yang.TypeReference
import io.typefox.yang.yang.Typedef
import io.typefox.yang.yang.Unique
import io.typefox.yang.yang.Unknown
import io.typefox.yang.yang.Uses
import io.typefox.yang.yang.When
import io.typefox.yang.yang.YangPackage
import java.util.ArrayList
import java.util.List
import java.util.regex.Pattern
import org.eclipse.emf.common.util.URI
import org.eclipse.emf.ecore.EObject
import org.eclipse.emf.ecore.resource.Resource
import org.eclipse.emf.ecore.resource.ResourceSet
import org.eclipse.emf.ecore.util.EcoreUtil
import org.eclipse.xtend.lib.annotations.Data
import org.eclipse.xtext.EcoreUtil2
import org.eclipse.xtext.naming.QualifiedName
import org.eclipse.xtext.resource.EObjectDescription
import org.eclipse.xtext.resource.IEObjectDescription
import org.eclipse.xtext.resource.impl.ResourceDescriptionsData
import org.eclipse.xtext.resource.impl.ResourceDescriptionsProvider
import org.eclipse.xtext.scoping.IScope
import org.eclipse.xtext.util.Wrapper
import org.eclipse.xtext.util.internal.EmfAdaptable

import static io.typefox.yang.yang.YangPackage.Literals.*

import static extension org.eclipse.xtext.EcoreUtil2.*

/**
 * Links the imported modules and included submodules, as well as computing the IScopeContext for them. 
 */
class ScopeContextProvider {
	
	@EmfAdaptable
	@Data
	private static class Adapter {
		IScopeContext scopeContext
		QualifiedName nodePath
	}
	
	static def removeFromResourceSet(ResourceSet resourceSet) {
		resourceSet.resources.forEach [
			removeFromResource(it)
		]
	}
	
	static def removeFromResource(Resource resource) {
		resource.allContents.forEach[
			Adapter.removeFromEmfObject(it)
		]
	}

	@Inject Validator validator
	@Inject Linker linker
	@Inject ResourceDescriptionsProvider indexProvider
	@Inject extension YangExtensions
	@Inject XpathResolver xpathResolver
	@Inject YangPathProvider yangPathProvider
	
	def IScopeContext findScopeContext(EObject node) {
		val module = EcoreUtil2.getContainerOfType(node, AbstractModule)
		if (module === null) {
			throw new IllegalStateException("Object "+node+" not contained in a module.")
		}
		// trigger computation
		var result = getScopeContext(module)
		var current = node
		do {
			val candidate = Adapter.findInEmfObject(current)
			if (candidate !== null) {
				return candidate.scopeContext
			}
			current = current.eContainer
		} while (current !== null)
		return result
	}
	
	def QualifiedName findSchemaNodeName(EObject node) {
		val adapter = Adapter.findInEmfObject(node)
		return adapter?.getNodePath
	}
	
	def IScopeContext getScopeContext(AbstractModule module) {
		val existing = Adapter.findInEmfObject(module)
		if (existing !== null) {
			return existing.scopeContext
		}
		val moduleScope = module.eResource.moduleScope
		val result = new ScopeContext(
			moduleScope,
			module.prefix,
			module.getModuleName(moduleScope)
		)
		new Adapter(result, QualifiedName.EMPTY).attachToEmfObject(module)
		
		handleGeneric(module, QualifiedName.EMPTY, result, true)
		return result
	}
	
	private def IScope getModuleScope(Resource resource) {
		val index = indexProvider.getResourceDescriptions(resource)
		val yangPathModuleScope = new YangModuleScope(IScope.NULLSCOPE, new ResourceDescriptionsData(yangPathProvider.getYangPath(resource)))
		return new YangModuleScope(yangPathModuleScope, index)
	}
	
	private def String getModuleName(AbstractModule module, IScope moduleScope) {
		if (module instanceof Submodule) {
			val superModule = getBelongingModule(module, moduleScope)
			if (superModule !== null && !superModule.eIsProxy)
				return superModule.name
		}
		return module.name
	}
	
	private def Module getBelongingModule(Submodule submodule, IScope moduleScope) {
		val belongsTo = submodule.substatements.filter(BelongsTo).head
		if (belongsTo === null) {
			return null
		}
		return linker.<Module>link(belongsTo, BELONGS_TO__MODULE) [ name |
			moduleScope.getSingleElement(name)
		]
	}
	
	protected def addToDefinitionScope(SchemaNode node, IScopeContext ctx) {
		if (node.name === null) {
			// broken model be graceful
			return;
		}
		val n = QualifiedName.create(node.name) 
		val scopeAndName = switch node {
			Grouping : ctx.groupingScope -> 'A grouping'
			Typedef : ctx.typeScope -> 'A type'
			Identity : ctx.identityScope -> 'An identity'
			Extension : ctx.extensionScope -> 'An extension'
			Feature : ctx.featureScope -> 'A feature'
		}
		if (scopeAndName !== null) {
			if (scopeAndName.key.tryAddLocal(n, node) != MapScope.AddResult.OK) {
				validator.addIssue(node, SCHEMA_NODE__NAME, '''«scopeAndName.value» with the name '«n»' already exists.''', IssueCodes.DUPLICATE_NAME)
			}
		}
	}
	
	protected dispatch def void computeScope(EObject node, QualifiedName nodePath, IScopeContext ctx, boolean isConfig) {
		handleGeneric(node, nodePath, ctx, isConfig)
	}
	
	protected dispatch def void computeScope(Refine node, QualifiedName nodePath, IScopeContext ctx, boolean isConfig) {
		node.node.doLinkNodeLater(nodePath, ctx)
		handleGeneric(node, nodePath, ctx, isConfig)
	}
	
	protected dispatch def void computeScope(Augment node, QualifiedName nodePath, IScopeContext ctx, boolean isConfig) {
		if (node.path !== null) {
			node.path.doLinkNodeLater(nodePath, ctx)
		}
		handleGeneric(node, nodePath, ctx, isConfig)
	}
	
	private def doLinkNodeLater(SchemaNodeIdentifier identifier, QualifiedName nodePath, IScopeContext context) {
		context.runAfterAll [
			internalLinkNode(identifier, nodePath, context)
		]
	}
	
	private def QualifiedName internalLinkNode(SchemaNodeIdentifier identifier, QualifiedName nodePath, IScopeContext context) {
		if (identifier.target !== null) {
			internalLinkNode(identifier.target, nodePath, context) 
		}
		val qn = identifier.internalGetQualifiedName(nodePath, context)
		linker.link(identifier, YangPackage.Literals.SCHEMA_NODE_IDENTIFIER__SCHEMA_NODE) [
			context.schemaNodeScope.getSingleElement(qn)
		]
		return qn
	}
	
	protected dispatch def void computeScope(TypeReference node, QualifiedName nodePath, IScopeContext ctx, boolean isConfig) {
		ctx.onResolveDefinitions [
			linker.link(node, TYPE_REFERENCE__TYPE) [ name |
				if (name.segmentCount == 2 && ctx.localPrefix !== null && name.startsWith(ctx.localPrefix)) {
					return ctx.typeScope.getSingleElement(name.skipFirst(1))
				}
				return ctx.typeScope.getSingleElement(name)
			]
		]
		handleGeneric(node, nodePath, ctx, isConfig)
	}
	
	protected dispatch def void computeScope(Uses node, QualifiedName nodePath, IScopeContext ctx, boolean isConfig) {
		handleGeneric(node, nodePath, ctx, isConfig)
		ctx.onComputeNodeScope [
			if (node.grouping?.node !== null) {
				val inliningCtx = new GroupingInliningScopeContext(ctx)
				for (child : node.grouping.node.substatements) {
					inlineGrouping(child, nodePath, inliningCtx, isConfig)
				}
			}
		]
	}
	
	private def boolean handleConfig(Statement statement, boolean isConfig) {
		// start fresh on grouping
		if (statement instanceof Grouping) {
			return true;
		}
		val configStmnt = statement.substatements.filter(Config).head
		if (configStmnt === null) {
			return isConfig
		}
		
		if (configStmnt.isConfig.trim.toLowerCase == 'true') {
			if (!isConfig) {
				validator.addIssue(configStmnt, YangPackage.Literals.CONFIG__IS_CONFIG, "Cannot add configuration data as a child of non-config data.", IssueCodes.INVALID_CONFIG)
			}	
			return true;	
		} 
		return false;
	}
	
	private def dispatch void inlineGrouping(Statement statement, QualifiedName name, GroupingInliningScopeContext context, boolean isConfig) {
	}
	private def dispatch void inlineGrouping(Grouping statement, QualifiedName name, GroupingInliningScopeContext context, boolean isConfig) {
	}
	private def dispatch void inlineGrouping(Typedef statement, QualifiedName name, GroupingInliningScopeContext context, boolean isConfig) {
	}
	
	private def dispatch void inlineGrouping(Uses statement, QualifiedName name, GroupingInliningScopeContext context, boolean isConfig) {
		if (statement.grouping !== null) {
			if (statement.isUsesGroupingSelf) {
				validator.addIssue(statement, SCHEMA_NODE__NAME, '''Grouping '«statement.grouping.node.name»' reference to itself.''', IssueCodes.GROUPING_REFERENCE_TO_ITSELF)
				return
			}
			for (subStmnt : statement.grouping.node.substatements) {
				inlineGrouping(subStmnt, name, context, isConfig)
			}
			for (subStmnt : statement.substatements.filter(Augment)) {
				_inlineGrouping(subStmnt, name, context, isConfig)
			}
		}
	}
	
	private def boolean isUsesGroupingSelf(Uses uses) {
		val refGrping = uses.grouping.node
		var container = uses.eContainer
		while (container !== null && !(container instanceof AbstractModule)) {
			if (container === refGrping) return true
			if (container instanceof Augment) {
				container = container.path?.eGet(SCHEMA_NODE_IDENTIFIER__SCHEMA_NODE, false) as EObject
			} else {
				container = container?.eContainer
			}
		}
		return false
	}
	
	private def dispatch void inlineGrouping(SchemaNode statement, QualifiedName name, GroupingInliningScopeContext context, boolean isConfig) {
		val newPath = getQualifiedName(statement, name, context)
		var newIsConfig = handleConfig(statement, isConfig) 
		if (newPath != name) {
			statement.addToNodeScope(newPath, context, newIsConfig)
		}
		for (subStmnt : statement.substatements) {
			inlineGrouping(subStmnt, newPath, context, newIsConfig)
		}
	}
	
	private def dispatch void inlineGrouping(Augment statement, QualifiedName name, GroupingInliningScopeContext context, boolean isConfig) {
		val newPath = _getQualifiedName(statement, name, context)
		var newIsConfig = handleConfig(statement, isConfig) 
		for (subStmnt : statement.substatements) {
			inlineGrouping(subStmnt, newPath, context, newIsConfig)
		}
	}
	
	protected dispatch def void computeScope(GroupingRef node, QualifiedName nodePath, IScopeContext ctx, boolean isConfig) {
		ctx.onResolveDefinitions [
			linker.link(node, GROUPING_REF__NODE) [ name |
				if (name.segmentCount == 2 && ctx.localPrefix !== null && name.startsWith(ctx.localPrefix)) {
					return ctx.groupingScope.getSingleElement(name.skipFirst(1))
				}
				return ctx.groupingScope.getSingleElement(name)
			]
		]
		handleGeneric(node, nodePath, ctx, isConfig)
	}
	
	protected dispatch def void computeScope(Base node, QualifiedName nodePath, IScopeContext ctx, boolean isConfig) {
		ctx.onResolveDefinitions [
			linker.link(node, BASE__REFERENCE) [ name |
				ctx.identityScope.getSingleElement(name)
			]
		]
		handleGeneric(node, nodePath, ctx, isConfig)
	}
	
	protected dispatch def void computeScope(FeatureReference node, QualifiedName nodePath, IScopeContext ctx, boolean isConfig) {
		ctx.onResolveDefinitions [
			linker.link(node, FEATURE_REFERENCE__FEATURE) [ name |
				ctx.featureScope.getSingleElement(name)
			]
		]
		handleGeneric(node, nodePath, ctx, isConfig)
	}
	
	protected dispatch def void computeScope(Unknown node, QualifiedName nodePath, IScopeContext ctx, boolean isConfig) {
		ctx.onResolveDefinitions [
			linker.link(node, UNKNOWN__EXTENSION) [ name |
				ctx.extensionScope.getSingleElement(name)
			]
		]
		handleGeneric(node, nodePath, ctx, isConfig)
	}
	
	protected dispatch def void computeScope(KeyReference node, QualifiedName nodePath, IScopeContext ctx, boolean isConfig) {
		ctx.runAfterAll [
			linker.link(node, KEY_REFERENCE__NODE) [ syntaxName |
				val result = ctx.schemaNodeScope.allElements.filter[ candidate |
					if (candidate.EClass !== LEAF) {
						return false
					} 
					if (candidate.name.lastSegment != syntaxName.lastSegment) {
						return false
					} 
					val np = nodePath
					return candidate.name.skipLast(2).equals(np)
				].head
				if (result !== null && result.userDataKeys.contains(NO_CONFIG_USER_DATA) === isConfig) {
					validator.addIssue(node, YangPackage.Literals.KEY_REFERENCE__NODE, "The list's keys must have the same `config` value as the list itself.", IssueCodes.INVALID_CONFIG)
				}
				return result
			]
		]
		handleGeneric(node, nodePath, ctx, isConfig)
	}
	
	protected dispatch def void computeScope(Unique node, QualifiedName nodePath, IScopeContext ctx, boolean isConfig) {
		for (identifier : node.references) {
			this.doLinkNodeLater(identifier, nodePath, ctx)
		}
		handleGeneric(node, nodePath, ctx, isConfig)
	}
	
	protected dispatch def void computeScope(Deviation node, QualifiedName nodePath, IScopeContext ctx, boolean isConfig) {
		this.doLinkNodeLater(node.reference, nodePath, ctx)
		handleGeneric(node, nodePath, ctx, isConfig)
	}
	
	protected dispatch def void computeScope(When when, QualifiedName nodePath, IScopeContext ctx, boolean isConfig) {
		ctx.runAfterAll [
			xpathResolver.doResolve(when.condition, nodePath, ctx)
		]
		handleGeneric(when, nodePath, ctx, isConfig)
	}
	
	protected dispatch def void computeScope(Must must, QualifiedName nodePath, IScopeContext ctx, boolean isConfig) {
		ctx.runAfterAll [
			xpathResolver.doResolve(must.constraint, nodePath, ctx)
		]
		handleGeneric(must, nodePath, ctx, isConfig)
	}
	
	protected dispatch def void computeScope(Path path, QualifiedName nodePath, IScopeContext ctx, boolean isConfig) {
		ctx.runAfterAll [
			xpathResolver.doResolve(path.reference, nodePath, ctx)
		]
		handleGeneric(path, nodePath, ctx, isConfig)
	}
	
	protected def void handleGeneric(EObject node, QualifiedName nodePath, IScopeContext ctx, boolean isConfig) {
		var newIsConfig = isConfig
		if (node instanceof SchemaNode) {		
			node.addToDefinitionScope(ctx)
		}
		var newPath = nodePath
		if (node instanceof Statement) {
			newIsConfig = this.handleConfig(node, isConfig)
			newPath = getQualifiedName(node, nodePath, ctx)
			if (newPath != nodePath 
				&& !(node instanceof Refine)
				&& !(node instanceof Grouping)
				&& !(node instanceof Augment)
				&& !(node instanceof Deviation)) {
				node.addToNodeScope(newPath, ctx, newIsConfig)
			}
		}
		val context = switch node {
			Grouping: {
				val scope = new LocalNodeScopeContext(ctx)
				new Adapter(scope, newPath).attachToEmfObject(node)
				scope
			}
			Deviation case node.reference !== null:
				new DeviationScopeContext(ctx, node)
			SchemaNode: {
				val scope = Adapter.findInEmfObject(node)?.scopeContext ?: new LocalScopeContext(ctx)
				new Adapter(scope, newPath).attachToEmfObject(node)
				scope
			}
			default:
				ctx
		}
		for (child : node.eContents) {
			computeScope(child, newPath, context, newIsConfig)
		}
	}
	
	static val NO_CONFIG_USER_DATA = 'NO_CONFIG'
	
	private def void addToNodeScope(EObject node, QualifiedName name, IScopeContext ctx, boolean isConfig) {
		ctx.onComputeNodeScope [
			val options = if (isConfig) emptyMap else #{NO_CONFIG_USER_DATA -> 't'}
			val result = ctx.schemaNodeScope.tryAddLocal(name, node, options)
			if (result != MapScope.AddResult.OK) {
				var code = IssueCodes.DUPLICATE_NAME
				if (result == MapScope.AddResult.DUPLICATE_PARENT) {
					// In case the name is already used in a belongs-to module, mark the duplicate name as warning
					val belonging = node.getContainerOfType(Submodule)?.getBelongingModule(ctx.moduleScope)
					if (belonging !== null) {
						val existing = ctx.schemaNodeScope.parent.getSingleElement(name)
						if (existing !== null && existing.EObjectURI.trimFragment == belonging.eResource.URI)
							code = IssueCodes.DUPLICATE_NAME_BELONGSTO
					}
				}
				validator.addIssue(node, SCHEMA_NODE__NAME, '''A schema node with the name '«name»' already exists.''', code)
			}
		]
	}

	protected dispatch def void computeScope(BelongsTo element, QualifiedName currentPrefix, IScopeContext ctx, boolean isConfig) {
		val importedModule = linkImportedModule(element, ctx)
		if (importedModule !== null && !importedModule.eIsProxy) {
			val prefix = element.prefix
			if (prefix === null) {
				validator.addIssue(element, BELONGS_TO__MODULE, "The 'prefix' statement is mandatory.", IssueCodes.MISSING_PREFIX)
			} else {
				ctx.moduleBelongingSubModules.add(getScopeContext(importedModule))
			}
		}
		handleGeneric(element, currentPrefix, ctx, isConfig);
	}
	
	private def Module linkImportedModule(BelongsTo element, IScopeContext ctx) {
		return linker.link(element, BELONGS_TO__MODULE) [ name |
			ctx.moduleScope.getSingleElement(name)
		]
	}

	protected dispatch def void computeScope(AbstractImport element, QualifiedName currentPrefix, IScopeContext ctx, boolean isConfig) {
		val importedModule = linkImportedModule(element, ctx)
		val prefix = element.prefix
		
		if (importedModule instanceof Submodule) {
			if (element instanceof Import) {
				validator.addIssue(element, null, '''The submodule '«importedModule.name»' needs to be 'included' not 'imported'.''', IssueCodes.IMPORT_NOT_A_MODULE)
			}
			val module = findContainingModule(element)
			val belongingModule = importedModule.getBelongingModule(ctx.moduleScope)
			if (belongingModule !== null && belongingModule !== module) {
				validator.addIssue(element, ABSTRACT_IMPORT__MODULE, '''The imported submodule '«importedModule.name»' belongs to the different module '«belongingModule.name»'.''', IssueCodes.INCLUDED_SUB_MODULE_BELONGS_TO_DIFFERENT_MODULE)			
			} else {	
				ctx.moduleBelongingSubModules.add(getScopeContext(importedModule))
			}
		}
		if (importedModule instanceof Module) {
			if (element instanceof Include) {
				validator.addIssue(element, null, '''The module '«importedModule.name»' needs to be 'imported' not 'included'.''', IssueCodes.INCLUDE_NOT_A_SUB_MODULE)
			}
			if (prefix === null) {
				validator.addIssue(element, ABSTRACT_IMPORT__MODULE, "The 'prefix' statement is mandatory.", IssueCodes.MISSING_PREFIX)
			} else {
				ctx.importedModules.put(prefix, getScopeContext(importedModule))
			}
		}
	}
	
	private def linkImportedModule(AbstractImport element, IScopeContext ctx) {
		val importedRevisionStatement = element.substatements.filter(RevisionDate).head
		linker.<AbstractModule>link(element, ABSTRACT_IMPORT__MODULE) [ name |
			val candidates = ctx.moduleScope.getElements(name)
			val revisionToModule = LinkedHashMultimap.create
			for (candidate : candidates) {
				val revision = candidate.getUserData(ResourceDescriptionStrategy.REVISION)
				if (revision === null) {
					revisionToModule.put("", candidate)
				} else {
					revisionToModule.put(revision, candidate)
				}
			}
			if (revisionToModule.empty)
				return null
			
			val matches = newArrayList
			if (importedRevisionStatement !== null) {
				linker.<Revision>link(importedRevisionStatement, REVISION_DATE__DATE) [ revisionName |
					val revisionModules = revisionToModule.get(revisionName.toString).sortBy[EObjectURI.trimFragment.toString]
					if (revisionModules.isEmpty) {
						// date will not be linked, that's enough as an error message
						return null
					}
					matches += revisionModules
					val importedModule = EcoreUtil.resolve(revisionModules.head.EObjectOrProxy, element) as AbstractModule
					val revisionToBeLinked = importedModule.substatements.filter(Revision).findFirst[revision == revisionName.toString]
					if (revisionToBeLinked === null)
						// revision is from filename, so nothing to link here
						return Linker.ROOT 
					else
						return EObjectDescription.create(revisionName, revisionToBeLinked)
				]
			}
			
			if (matches.empty) {
				matches += revisionToModule.get(revisionToModule.keys.max)
			}
			val filtered = filterUnrelatedModules(element.eResource, matches)
			if (filtered.size > 1) {
				val modulePaths = filtered.map[EObjectURI.path].stripCommonPath
				validator.addIssue(element, ABSTRACT_IMPORT__MODULE,
					'''Multiple modules '«name»' with matching revision are available [«modulePaths.join(', ')»]''',
					IssueCodes.AMBIGUOUS_IMPORT)
			}
			return filtered.head
		]
	}
	
	private def List<IEObjectDescription> filterUnrelatedModules(Resource resource, List<IEObjectDescription> candidates) {
		if (candidates.size <= 1)
			return candidates
		val resourceDir = resource.URI.directory
		if (resourceDir === null)
			return candidates
		val result = new ArrayList(candidates)
		result.removeIf[candidate |
			val dir = candidate.EObjectURI.directory
			!resourceDir.startsWith(dir) && !dir.startsWith(resourceDir)
		]
		if (result.empty)
			return candidates
		else
			return result
	}
	
	private def getDirectory(URI uri) {
		if (uri === null)
			return null
		val path = uri.path
		val endIndex = path.lastIndexOf('/')
		if (endIndex >= 0)
			return path.substring(0, endIndex)
		else
			return path
	}
	
	private def stripCommonPath(Iterable<String> paths) {
		val head = paths.head
		val tail = paths.tail
		val matcher = Pattern.compile('/').matcher(head)
		val commonIndex = Wrapper.wrap(0)
		while (matcher.find) {
			val prefix = head.substring(0, matcher.end)
			if (tail.forall[startsWith(prefix)])
				commonIndex.set = matcher.end
		}
		return paths.map[substring(commonIndex.get)]
	}
	
	private def findContainingModule(EObject obj) {
		val candidate = EcoreUtil2.getContainerOfType(obj, AbstractModule)
		if (candidate instanceof Submodule) {
			return candidate.substatements.filter(BelongsTo).head.module
		}
		return candidate
	}
	
	private def dispatch QualifiedName getQualifiedName(Statement node, QualifiedName p, IScopeContext ctx) {
		return p
	}
	
	private def dispatch QualifiedName getQualifiedName(Grouping node, QualifiedName p, IScopeContext ctx) {
		return QualifiedName.EMPTY
	}
	
	private def dispatch QualifiedName getQualifiedName(Extension node, QualifiedName p, IScopeContext ctx) {
		return p
	}
	
	private def dispatch QualifiedName getQualifiedName(Identity node, QualifiedName p, IScopeContext ctx) {
		return p
	}
	
	private def dispatch QualifiedName getQualifiedName(Feature node, QualifiedName p, IScopeContext ctx) {
		return p
	}
	
	private def dispatch QualifiedName getQualifiedName(Typedef node, QualifiedName p, IScopeContext ctx) {
		return p
	}
	
	private def dispatch QualifiedName getQualifiedName(Input node, QualifiedName p, IScopeContext ctx) {
		return p.append(ctx.moduleName).append('input')
	}
	
	private def dispatch QualifiedName getQualifiedName(Output node, QualifiedName p, IScopeContext ctx) {
		return p.append(ctx.moduleName).append('output')
	}
	
	private def dispatch QualifiedName getQualifiedName(SchemaNode node, QualifiedName p, IScopeContext ctx) {
		var prefix = p
		// data nodes directly contained in choices get an implicit case (see RFC7950 7.9.2)
		if (node.eContainer instanceof Choice && !(node instanceof Case)) {
			prefix = p.append(ctx.moduleName).append(node.name)
			node.addToNodeScope(prefix, ctx, true)
		}
		val result = prefix.append(ctx.moduleName).append(node.name)
		// add implicit input / output if they do not exist (see RFC 7950 7.14)
		if (node instanceof Rpc || node instanceof Action) {
			val input = node.substatements.filter(Input).head
			if (input === null) {
				val inputName = result.append(ctx.moduleName).append('input')
				node.addToNodeScope(inputName, ctx, true)
			}
			val output = node.substatements.filter(Output).head
			if (output === null) {
				val outputName = result.append(ctx.moduleName).append('output')
				node.addToNodeScope(outputName, ctx, true)
			}
		}
		return result
	}
	
	private def dispatch QualifiedName getQualifiedName(Augment node, QualifiedName p, IScopeContext ctx) {
		if (node.path === null) {
			return p
		}
		return internalGetQualifiedName(node.path, p, ctx)
	}
	
	private def dispatch QualifiedName getQualifiedName(Deviation node, QualifiedName p, IScopeContext ctx) {
		if (node.reference === null) {
			return p
		}
		return internalGetQualifiedName(node.reference, p, ctx)
	}
	
	private def dispatch QualifiedName getQualifiedName(Refine node, QualifiedName p, IScopeContext ctx) {
		if (node.node === null) {
			return p
		}
		return internalGetQualifiedName(node.node, p, ctx)
	}
	
	private def QualifiedName internalGetQualifiedName(SchemaNodeIdentifier identifier, QualifiedName p, IScopeContext ctx) {
		val prefix = if (identifier.target !== null) {
			internalGetQualifiedName(identifier.target, p, ctx)			
		} else if (identifier.isAbsolute) {
			QualifiedName.EMPTY
		} else {
			p
		}
		val qn = linker.getLinkingName(identifier, YangPackage.Literals.SCHEMA_NODE_IDENTIFIER__SCHEMA_NODE)
		if (qn !== null) {
			var firstSeg = ctx.moduleName
			if (qn.segmentCount === 2) {
				val importedName = ctx.importedModules.get(qn.firstSegment)?.moduleName
				if (importedName !== null)
					firstSeg = importedName
			} else if (ctx instanceof DeviationScopeContext) {
				val deviationName = internalGetQualifiedName(ctx.deviation.reference, QualifiedName.EMPTY, ctx.original)
				if (deviationName.segmentCount >= 2)
					firstSeg = deviationName.getSegment(deviationName.segmentCount - 2)
			}
			val secondSeg = qn.lastSegment
			return prefix.append(firstSeg).append(secondSeg)
		} else if (identifier.schemaNode !== null && !identifier.schemaNode.eIsProxy()) {
			val moduleName = identifier.schemaNode.getContainerOfType(AbstractModule)?.name
			if (moduleName !== null && identifier.schemaNode.name !== null)
				return prefix.append(moduleName).append(identifier.schemaNode.name)
		} 
		return prefix
	}
	
}
