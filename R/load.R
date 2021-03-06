




#' Loads a meta definition.
#'
#' @param con a connection containing the meta data
#'
#' @examples
#' filePath <- system.file("extdata", "context1.yaml", package="datap")
#' context <- Load(filePath)
#'
#' @importFrom yaml yaml.load
#' @importFrom data.tree FromListExplicit Do isNotRoot
#' @importFrom utils capture.output
#' @export
Load <- function(con) {
  yamlString <- paste0(readLines(con), collapse = "\n")
  lol <- yaml.load(yamlString)

  tree <- CreateRawTree(lol)

  errors <- CheckSyntaxRawTree(tree)
  if (errors$`.hasErrors`) {
    stop("Context contains syntax errors! Run CheckSyntax(con) to get an error report.")
  }

  ResolveFlow(tree)

  aggregationErrors <- CheckAggregationTree(tree)
  if (aggregationErrors$`.hasErrors`) {
    stop("Context contains aggregation errors! Run CheckAggregation(con) to get an error report.")
  }

  ParseTree(tree)

  return (tree)
}


#' @importFrom data.tree Node FromListSimple
CreateRawTree <- function(lol) {

  rawTree <- FromListSimple(lol, nameName = NULL)

  ReplaceNodesWithLol(rawTree, "variables", lol)
  ReplaceNodesWithLol(rawTree, "parameters", lol)
  ReplaceNodesWithLol(rawTree, "attributes", lol)

  return (rawTree)

}



ResolveFlow <- function(tree) {

  #prune modules
  data.tree::Prune(tree, pruneFun = function(node) !identical(node$type, "module"))

  #prune branches without a tap ()
  #really necessary?
  data.tree::Prune(tree, pruneFun = function(node) {
    any(node$Get("type") == "tap", na.rm = TRUE) || any(node$Get("type", traversal = "ancestor") == "tap", na.rm = TRUE)
  })

  #set empty lists
  tree$Do(function(node) node$arguments <- as.list(node$arguments),
          filterFun = function(x) !is.null(x$arguments))

  tree$Do(function(node) node$rank <- node$parent$name,
          filterFun = function(x) identical(x$parent$type, "pipe") ||
                                  identical(x$parent$type, "junction") ||
                                  identical(x$parent$type, "tap")
          )


  tree$Do(function(node) node$downstream <- GetDownstreamPath(node), filterFun = isNotRoot)




}



#' @importFrom data.tree isNotRoot isLeaf
ParseTree <- function(tree) {
  tree$name <- "context"
  tree$type <- "context"

  class(tree) <- c("context", class(tree))

  #data.tree:::print.Node(tree, ds = function(joint) paste0(joint$downstream, collapse = "|"))

  tree$Do(function(joint) {
    ds <- data.tree::Navigate(joint, joint$downstream)
    ds$upstream[[joint$name]] <- joint
  },
  filterFun = isNotRoot)
  #tree$Do(function(joint) joint$upstream <- list(), filterFun = isLeaf)

  #data.tree:::print.Node(tree, ds = function(joint) paste0(l(joint$upstream, "name"), collapse = "|"))


  tree$Do(function(node) class(node) <- c("tap", class(node)), filterFun = function(x) identical(x$type, "tap"))

  #add dummy function to pipes
  tree$Do(function(node) node$`function` <- 'identity(.$inflow)', filterFun = function(node) identical(node$type, "pipe"))

  #parse expressions
  tree$Do(function(node) node$variablesE <- ParseExpressions(node$variables), filterFun = function(node) length(node$variables) > 0)
  tree$Do(function(node) node$conditionE <- ParseExpression(node$condition), filterFun = function(node) length(node$condition) > 0)
  tree$Do(function(node) node$functionE <- ParseExpression(node$`function`), filterFun = function(node) length(node$`function`) > 0)
  tree$Do(function(node) node$parametersE <- ParseExpressions(node$parameters), filterFun = function(node) length(node$parameters) > 0)


  tree$Do(EvaluateBuildTimeExpressions, doConst = FALSE)

  #set parameters, starting from source towards downstream
  tree %>%
    Traverse(traversal = function(node) node$upstream,
             filterFun = function(node)!(node$type %in% JOINT_TYPES_STRUCTURE)) %>%
    rev %>%
    Do(function(node) node$parametersE <- GetRequiredParameters(node))


  Traverse(tree,
           filterFun = function(node) !is.null(node$type) && node$type %in% JOINT_TYPES_FUN) -> traversal

  traversal %>% rev %>%
    Do(function(joint) joint$tap <- ParseFun(joint))

  tree$Do(EvaluateBuildTimeExpressions, doConst = TRUE)

  tree$Do(fun = function(node) node$tap <- node$children[[1]]$tap,
          filterFun = function(node) identical(node$type, "tap"))

  tree$TapNames <- function() names(tree$children)
}

EvaluateBuildTimeExpressions <- function(node, doConst) {
  if (!is.null(node$variablesE)) for (e in node$variablesE) EvaluateExpressionBuild(e, node, doConst)
  if (!is.null(node$conditionE)) EvaluateExpressionBuild(node$conditionE, node, doConst)
  if (!is.null(node$functionE)) EvaluateExpressionBuild(node$functionE, node, doConst)
  if (!is.null(node$parametersE)) for (e in node$parametersE) if (!is.null(e)) EvaluateExpressionBuild(e, node, doConst)
}

ParseExpressions <- function(expressionsList) {
  for (i in 1:length(expressionsList)) {
    if (length(expressionsList[[i]]) > 0) expressionsList[[i]] <- ParseExpression(expressionsList[[i]])
  }
  return (expressionsList)
}



ReplaceNodesWithLol <- function(rawTree, name, lol) {
  rawTree$Do(function(node) {
    for(n in node$path[-1]) lol <- lol[[n]]
    parent <- node$parent
    parent$RemoveChild(name)
    parent[[name]] <- lol
  },
  filterFun = function(node) node$name == name)
}




GetTap <- function(joint) {
  if (joint$type == "tap") return (joint)
  if (joint$isRoot) return (NULL)
  return (GetTap(joint$parent))
}









GetDownstreamPath <- function(joint) {
  #if (joint$name == "final") browser()
  if (!joint$type %in% JOINT_TYPES_FUN) return ("..") #structure, tap
  parentType <- joint$parent$type
  if (identical(parentType, "tap")) return ("..")
  if (identical(parentType, "junction")) return ("..")
  if (identical(parentType, "pipe")) {
    if (joint$position == 1) return ("..")
    ds <- joint$parent$children[[joint$position - 1]]
    #if (identical(ds$type, "junction")) stop(paste0("No element allowed after junction ", ds$name, "!"))
    pth <- GetSourcesPath(ds, path = paste("..", ds$name, sep = "/"))
    return (pth)
  }
  else stop(paste0("Unexpected joint parent type ", parentType, " of joint ", joint$name))
}






GetSourcesPath <- function(joint, path = ".") {

  if (joint$isLeaf) return (path)
  if (identical(joint$type, "junction")) {
    usjs <- joint$children
  } else if (identical(joint$type, "pipe")) {
    usjs <- joint$children[joint$count]
  } else {
    stop("Unexpected Error")
  }
  res <- sapply(usjs, function(j) GetSourcesPath(j, paste(path, j$name, sep = "/")))
  return (res)
}








# Finds the tap parameters that will be used on
# this joint or on any of its upstream joints
# Assume that this has already been called upstream
# We define as parameters all variables that are
# not resolved
# Store parameters in parameters list
GetRequiredParameters <- function(joint) {

  myParameterNames <- GetUnresolvedVariables(joint)

  if (!is.null(joint$upstream)) {
    Get(joint$upstream, function(j) names(j$parametersE), simplify = FALSE, nullAsNa = FALSE) %>%
      do.call(c, .) %>%
      c(myParameterNames) %>%
      unique ->
      myParameterNames
  }

  tap <- GetTap(joint)
  myParameters <- tap$parametersE
  for (paramName in myParameterNames) {
    if (!paramName %in% names(tap$parametersE)) {
      myParameters[paramName] <- list(NULL)
    }
  }
  myParameters <- myParameters[names(myParameters) %in% myParameterNames]

  return (myParameters)


}




GetUnresolvedVariables <- function(joint) {
  variables <- lapply(joint$variablesE, function(expression) GetVariablesInExpression(expression))
  GetVariablesInExpression(joint$conditionE) %>% c(variables) -> variables
  GetVariablesInExpression(joint$functionE) %>% c(variables) -> variables
  variables %>% unlist %>% unname %>% extract(., !. %in% VARIABLE_RESERVED_NAMES_CONST) %>% return
  #GetVariableValue(joint, nme)
}



