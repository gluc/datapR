


#'@export
ParseExpression <- function(expressionString) {
  expressionString <- as.character(expressionString)
  vecs <- Node$new("function",
                   originalExpressionString = expressionString)

  vecs$expressionV <- strsplit(expressionString, "")[[1]]

  vecs$pos <- matrix(FALSE, ncol = 8, nrow = length(vecs$expressionV))
  colnames(vecs$pos) <- c("tapTimeFun", "open", "close", "arg", "eq" ,"str", "var", "ws")
  vecs$pos[, 'tapTimeFun'] <- (vecs$expressionV == ".")
  vecs$pos[, 'open'] <- (vecs$expressionV == "(")
  vecs$pos[, 'close'] <- (vecs$expressionV == ")")
  vecs$pos[, 'arg'] <- (vecs$expressionV == ",")
  vecs$pos[, 'eq'] <- (vecs$expressionV == "=")
  vecs$pos[, 'str'] <- (vecs$expressionV == "'" | vecs$expressionV == '"')
  vecs$pos[, 'var'] <- (vecs$expressionV == "$")
  vecs$pos[, 'ws'] <- (vecs$expressionV == " ")

  .ParseExpression(vecs)
  return (vecs)
}

.ParseExpression <- function(node) {
  #is this named?
  idx <- ParseFindArgumentName(node)

  #what is this?
  #function, argument, variable, R expression
  node$type <- ParseFindType(node, idx)
  idx <- ParseExecutionTime(node, idx)
  if (node$type == "fun") {
    ParseFunction(node, idx)
  } else if (node$type == "argument") {
    ParseArgument(node, idx)
  } else if (node$type == "variable") {
    node$variableName <- ParseVariableName(node, idx)
  } else if (node$type == "R") {
    node$expression <- trimws(paste0(node$expressionV, collapse = ""))
  } else stop (paste0("Unkown node type ", node$type))

}


ParseArgument <- function(node, idx) {
  while(node$pos[idx, 'ws']) idx <- idx + 1
  child <- node$AddChild(name = (node$count + 1))
  child$pos <- node$pos[idx:nrow(node$pos), , drop = FALSE]
  child$expressionV <- node$expressionV[idx:nrow(node$pos)]
  .ParseExpression(child)

}


ParseVariableName <- function(node, idx) {
  nme <- paste0(node$expressionV[-(1:idx)], collapse = "")
  nme <- trimws(nme)
  return (nme)
}


ParseFunction <- function(node, idx) {
  while(node$pos[idx, 'ws']) idx <- idx + 1
  idx <- ParseFunName(node, idx)
  repeat {
    argEndIdx <- ParseFindArgEndIdx(node, idx + 1)
    while(node$pos[idx, 'ws']) idx <- idx + 1
    child <- node$AddChild(name = (node$count + 1))
    child$pos <- node$pos[(idx + 1):(argEndIdx - 1), , drop = FALSE]
    child$expressionV <- node$expressionV[(idx + 1):(argEndIdx - 1)]
    .ParseExpression(child)
    idx <- argEndIdx
    while(node$pos[idx, 'ws']) idx <- idx + 1
    if (idx == nrow(node$pos) || (nrow(node$pos) > idx && all(node$pos[(idx + 1):nrow(node$pos), 'ws']))) break

  }
}


Evaluate <- function(expressionTree, variablesList) {

  expressionTree$Do(EvaluateNodeIfPossible, traversal = "post-order", variablesList = variablesList, executionTime = "tap" )

  unresolvedVariables <- expressionTree$Get("variableName", filterFun = function(expr) expr$type == "variable")
  if (length(unresolvedVariables) > 0) stop(paste0("Variables ", paste0(unresolvedVariables, collapse = ", "), " cannot be resolved!"))

  if (expressionTree$type != "value") {
    #this should only happen if aeap
    stop("datap error 1001. Please contact the package maintainer.")
  }

  return (expressionTree$value)
}


# This should be called on tap time. The expression tree
# is not changed.
Evaluate <- function(expressionTree, variablesList) {

  if (expressionTree$type == "R") {
    value <- eval(parse(text = expressionTree$expression))
    return (value)
  }

  else if (expressionTree$type == "variable") {
    if (!expressionTree$variableName %in% names(variablesList)) stop (paste0("Variable $", expressionTree$variableName, " unknown!"))
    return (variablesList[[expressionTree$variableName]])
  }

  else if (expressionTree$type == "argument") return (Evaluate(expressionTree$children[[1]], variablesList))

  else if (expressionTree$type == "fun") {
    argList <- Get(nodes = expressionTree$children, attribute = Evaluate, simplify = FALSE, variablesList)
    argListNames <- Get(expressionTree$children, function(node) if (is.null(node$argumentName)) return("") else return (node$argumentName), simplify = FALSE)

    if (!all(argListNames == "")) names(argList) <- argListNames
    else names(argList) <- NULL

    res <- do.call(expressionTree$funName, argList)
    return (res)
  }

  else if (expressionTree$type == "value") {
    return (expressionTree$value)
  }

  stop (paste0("Unknown expression type ", expressionTree$type))

}

# This is called build time. Expressions are evaluated where possible
# and variables are fetched from node and ancestors. This changes
# the expression tree upon evaluation.
EvaluateExpressionBuild <- function(expressionTree, node) {
  expressionTree$Do(EvaluateNodeBuild, traversal = "post-order", node)
}

EvaluateNodeBuild <- function(expressionTree, node) {
  if (expressionTree$executionTime == "tap") return()
  if (expressionTree$type == "R") {
    expressionTree$value <- eval(parse(text = expressionTree$expression))
    expressionTree$type <- "value"
  } else if (expressionTree$type == "variable") {
    val <- GetVariableValue(node, expressionTree$variableName)
    if (!is.null(val)) {
      expressionTree$value <- val
      expressionTree$type <- "value"
    }
  } else if (expressionTree$type == "argument") {
    child <- expressionTree$children[[1]]
    if (child$type == "value") {
      expressionTree$value <- child$value
      expressionTree$type <- "value"
    }
  } else if (expressionTree$type == "fun") {

    Get(expressionTree$children, function(node) node$children[[1]]$type == "value") %>%
      all ->
      evaluatable

    if (evaluatable) {

      argList <- Get(expressionTree$children, simplify = FALSE, "value")
      argListNames <- Get(expressionTree$children, function(node) if (is.null(node$argumentName)) return("") else return (node$argumentName), simplify = FALSE)
      if (!all(argListNames == "")) names(argList) <- argListNames
      else names(argList) <- NULL
      res <- do.call(expressionTree$funName, argList)
      expressionTree$type <- "value"
      expressionTree$value <- res
    }
  }

}

GetVariablesInExpression <- function(expression) {
  expression$Get(function(node) node$variableName, filterFun = function(node) node$type == "variable", simplify = FALSE)
}

ParseFindType <- function(node, idx) {
  while(node$pos[idx, 'ws']) idx <- idx + 1
  if (!node$isRoot && node$parent$type == "fun") return ("argument")

  for (i in idx:length(node$expressionV)) {
    if (node$pos[i, 'open']) return ("fun")
    if (any(node$pos[i, c("close", "arg", "eq" ,"str", "var") ])) break
  }

  if (node$pos[i, 'var']) return("variable")
  else return ("R")
}


ParseFindArgumentName <- function(node) {
  idx <- 1
  while(node$pos[idx, 'ws']) idx <- idx + 1
  for (i in idx:length(node$expressionV)) {
    if (node$pos[i, 'eq']) {
      nme <- paste0(node$expressionV[idx:(i-1)], collapse = "")
      node$argumentName <- trimws(nme)
      return (i + 1)
    }
    if (any(node$pos[i, c("tapTimeFun", "open", "close", "arg", "eq" ,"str", "var") ])) return (idx)
  }
  return (idx)
}



ParseFindArgEndIdx <- function(vecs, idx) {
  while(vecs$pos[idx, 'ws']) idx <- idx + 1
  str <- FALSE
  funLvl <- 1
  for (i in idx:nrow(vecs$pos)) {
    if (str && vecs$pos[i, 'str']) str <- FALSE
    else if (!str && vecs$pos[i, 'str']) str <- TRUE

    if (!str) {

      if (vecs$pos[i, 'open']) funLvl <- funLvl + 1
      else if (vecs$pos[i, 'close'] && funLvl > 1) funLvl <- funLvl - 1
      else if (funLvl == 1 && (vecs$pos[i, 'arg'] || vecs$pos[i, 'close'])) return(i)
    }

  }
}

ParseExecutionTime <- function(vecs, idx) {
  while(vecs$pos[idx, 'ws']) idx <- idx + 1
  if (vecs$type == "argument") {
    vecs$executionTime <- vecs$parent$executionTime
  } else if(vecs$pos[idx, 'tapTimeFun']) {
    vecs$executionTime <- "tap"
    idx <- idx + 1
  } else {
    #defaults: as early as possible (aeap)
    vecs$executionTime <- "aeap"
  }

  return (idx)
}

ParseFunName <- function(vecs, idx) {
  while(vecs$pos[idx, 'ws']) idx <- idx + 1
  idxo <- which(vecs$pos[, 'open'])[1]
  vecs$funName <- paste0(vecs$expressionV[idx:(idxo-1)], collapse = "")
  return (idxo)
}
