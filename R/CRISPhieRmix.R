#' CRISPhieRmix
#'
#' A tool for identifying interesting genes in large pooled CRISPRi and CRISPRa screen
#' using hierarchical mixture models
#'
#' @import sn
#' @import statmod
#' @import nloptr
#'
#' @name CRISPhieRmix
NULL
# > NULL

logSumLogVec <- function(logVec){
  log_max = max(logVec)
  logVec = logVec[-which.max(logVec)]
  return(log_max + log(1 + sum(exp(logVec - log_max))))
}

LogSumWeightedAverage <- function(logprobs, q){
  stopifnot(dim(logprobs)[2] == 2)
  r = sum(vapply(1:dim(logprobs)[1], function(i) logSumLogVec(c(log(q) + logprobs[i, 1],
                                                                log(1 - q) + logprobs[i, 2])),
                 FUN.VALUE = double(1)))
  return(r)
}

geneExpectations2Group <-function(x, geneIds, q, p,
                                  log_alt_guide_probs,
                                  log_null_guide_probs){
  log_null_gene_probs = by(log_null_guide_probs, geneIds, sum)
  logprobs = data.frame(log_alt_guide_probs = log_alt_guide_probs,
                        log_null_guide_probs = log_null_guide_probs)
  log_pos_gene_probs = by(logprobs, geneIds, function(y) LogSumWeightedAverage(y, q))
  log_denom = vapply(1:length(log_pos_gene_probs),
                     function(i)
                       logSumLogVec(c(log(p) + log_pos_gene_probs[i], log(1 - p) + log_null_gene_probs[i])),
                     FUN.VALUE = double(1))
  return(exp(log(p) + log_pos_gene_probs - log_denom))
}

gaussQuadGeneExpectation2Groups <- function(x, geneIds,
                                            log_alt_guide_probs,
                                            log_null_guide_probs,
                                            tau,
                                            nMesh = 100){
  lowerLim = tau
  upperLim = 1
  quad.points.weights = statmod::gauss.quad.prob(nMesh, dist = "uniform", l = lowerLim, u = upperLim)
  nGenes = length(levels(geneIds))

#  EZ_g.mat = vapply(1:nMesh, function(i) quad.points.weights$weights[i]*geneExpectations2Group(x, geneIds, q = quad.points.weights$nodes[i], p = lowerLim/quad.points.weights$nodes[i], log_alt_guide_probs = log_alt_guide_probs, log_null_guide_probs = log_null_guide_probs), FUN.VALUE = double(nGenes))
  #EZ_g.mat = t(EZ_g.mat)
  #return(apply(EZ_g.mat, 2, sum))

  return(integratedExpectation2groups(as.numeric(geneIds), log_alt_guide_probs,
                                      log_null_guide_probs, quad.points.weights$nodes,
                                      tau, quad.points.weights$weights) )
}

# function can be used for pos and neg by switching names
gaussQuadGeneExpectation3Groups <- function(x, geneIds,
                                            log_pos_guide_probs,
                                            log_neg_guide_probs,
                                            log_null_guide_probs,
                                            tau_pos, tau_neg,
                                            nMesh = 100){
  lowerLim = tau_pos + tau_neg
  upperLim = 1
  quad.points.weights = statmod::gauss.quad.prob(nMesh, dist = "uniform", l = lowerLim, u = upperLim)
  nGenes = length(levels(geneIds))
  return(integratedExpectation3groups(as.numeric(geneIds), log_pos_guide_probs,
                                      log_neg_guide_probs, log_null_guide_probs,
                                      quad.points.weights$nodes, tau_pos, tau_neg,
                                      quad.points.weights$weights) )
}

#integratedGeneExpectation2Groups <- function(x, geneIds,
#                                             log_alt_guide_probs,
#                                             log_null_guide_probs,
#                                             lowerLim = 0.1, upperLim = 1,
#                                             nMesh = 100){
#  q.grid = seq(from = lowerLim, to = upperLim, length = nMesh + 2)
#  q.grid = q.grid[-c(1, length(q.grid))]
#  nGenes = length(levels(geneIds))
#  EZ_g.mat = vapply(1:length(q.grid),
#                    function(i) geneExpectations2Group(x, geneIds, q = q.grid[i], p = lowerLim/q.grid[i],
#                                                       log_alt_guide_probs = log_alt_guide_probs,
#                                                       log_null_guide_probs = log_null_guide_probs),
#                    FUN.VALUE = double(nGenes))
#  return(apply(EZ_g.mat, 1, mean))
#}



skewtMixExpectationStep2comp <- function(x, skewtFit, mu, sigma, pq){
  log_pos_prob = log(pq) + dnorm(x, mean = mu, sd = sigma, log = TRUE)
  log_null_prob = log(1 - pq) + sn::dst(x, dp = skewtFit$dp, log = TRUE)
  log_denom = apply(cbind(log_pos_prob, log_null_prob), 1, logSumLogVec)
  return(exp(log_pos_prob - log_denom))
}

skewtMixExpectationStep3comp <- function(x, skewtFit,
                                         pqPos, pqNeg,
                                         muPos, muNeg,
                                         sigmaPos, sigmaNeg){
  log_pos_prob = log(pqPos) + dnorm(x, mean = muPos, sd = sigmaPos, log = TRUE)
  log_neg_prob = log(pqNeg) + dnorm(x, mean = muNeg, sd = sigmaNeg, log = TRUE)
  log_null_prob = log(1 - pqPos - pqNeg) + sn::dst(x, dp = skewtFit$dp, log = TRUE)

  log_denom = apply(cbind(log_pos_prob, log_neg_prob, log_null_prob), 1, logSumLogVec)
  return(list(posProbs = exp(log_pos_prob - log_denom),
              negProbs = exp(log_neg_prob - log_denom)))
}

skewtMixMaxStep2comp <- function(x, posProbs, skewtFit = NULL){
  pq = mean(posProbs)
  mu = mean(posProbs*x)/mean(posProbs)
  sigma = sqrt(mean(posProbs*(x - mu)^2)/mean(posProbs))
  if(is.null(skewtFit)){
    skewtFit = sn::st.mple(y = x, w = 1 - posProbs)
  }
  return(list(pq = pq, mu = mu, sigma = sigma, skewtFit = skewtFit))
}

skewtMixMaxStep3comp <- function(x, posProbs, negProbs, skewtFit = NULL){
  pqPos = mean(posProbs)
  pqNeg = mean(negProbs)
  muPos = mean(posProbs*x)/pqPos
  muNeg = mean(negProbs*x)/pqNeg
  sigmaPos = sqrt(mean(posProbs*(x - muPos)^2 )/pqPos)
  sigmaNeg = sqrt(mean(negProbs*(x - muNeg)^2)/pqNeg)

  if(is.null(skewtFit)){
    cat("refitting skewtFit \n")
    skewtFit = sn::st.mple(y = x, w = 1 - posProbs - negProbs)
  }
  return(list(pqPos = pqPos, pqNeg = pqNeg,
              muPos = muPos, muNeg = muNeg,
              sigmaPos = sigmaPos, sigmaNeg = sigmaNeg,
              skewtFit = skewtFit))
}

skewt2compLogLike <- function(x, pq, skewtFit, mu, sigma){
  log_pos_prob = log(pq) + dnorm(x, mean = mu, sd = sigma, log = TRUE)
  log_null_prob = log(1 - pq) + sn::dst(x, dp = skewtFit$dp, log = TRUE)
  return(sum(apply(cbind(log_pos_prob, log_null_prob), 1, logSumLogVec)))
}

skewt3compLogLike <- function(x, skewtFit,
                              pqPos, pqNeg,
                              muPos, muNeg,
                              sigmaPos, sigmaNeg){
  log_pos_prob = log(pqPos) + dnorm(x, mean = muPos, sd = sigmaPos, log = TRUE)
  log_neg_prob = log(pqNeg) + dnorm(x, mean = muNeg, sd = sigmaNeg, log = TRUE)
  log_null_prob = log(1 - pqPos - pqNeg) + sn::dst(x, dp = skewtFit$dp, log = TRUE)

  return(sum(apply(cbind(log_pos_prob, log_neg_prob, log_null_prob), 1, logSumLogVec)))
}


skewtEM2comp <- function(x, skewtFit = NULL, max_iter = 1000, tol = 1e-10,
                         pq = 0.1, mu = 4, sigma = 1, VERBOSE = FALSE){
  n_obs = length(x)
  providedFit = !is.null(skewtFit)
  loglike = -1e100;
  iter = 0;
  posProbs = rep(pq, times = n_obs)
  repeat{
    prevloglike = loglike
    # max step
    if(providedFit){
      updated_params = skewtMixMaxStep2comp(x, posProbs, skewtFit)
    }
    else{
      updated_params = skewtMixMaxStep2comp(x, posProbs, skewtFit = NULL)
    }
    pq = updated_params$pq
    mu = updated_params$mu
    sigma = updated_params$sigma
    skewtFit = updated_params$skewtFit
    # expectation step
    posProbs = skewtMixExpectationStep2comp(x, skewtFit, mu, sigma, pq)

    loglike = skewt2compLogLike(x, pq, skewtFit, mu, sigma)
    iter = iter + 1
    if(VERBOSE){
      cat("iter: ", iter, "\n")
      cat("loglike = ", loglike, "\n")
      cat("prevloglike = ", prevloglike, "\n")
      cat("mu = ", mu, "\n")
      cat("sigma = ", sigma, "\n")
      cat("pq = ", pq, "\n")
    }
    if(abs(loglike - prevloglike)/n_obs < tol | iter > max_iter){
      if(VERBOSE){
        cat("stop after iteration ", iter, "\n")
      }
      break
    }
  }
  return(list(posProbs = posProbs, skewtFit = skewtFit,
              pq = pq, mu = mu, sigma = sigma))
}

skewtEM3comp <- function(x, skewtFit = NULL,
                         max_iter = 1000, tol = 1e-10,
                         pqPos = 0.05, pqNeg = 0.05,
                         muPos = 5, muNeg = -5,
                         sigmaPos = 1, sigmaNeg = 1,
                         VERBOSE = FALSE){
  n_obs = length(x)
  providedFit = !is.null(skewtFit)
  prevloglike = -1e100;
  loglike = skewt3compLogLike(x, skewtFit, pqPos, pqNeg,
                              muPos, muNeg, sigmaPos, sigmaNeg)
  iter = 0;
  initial_expectations = skewtMixExpectationStep3comp(x, skewtFit, pqPos, pqNeg,
                                                      muPos, muNeg, sigmaPos, sigmaNeg)
  posProbs = initial_expectations$posProbs
  negProbs = initial_expectations$negProbs

  repeat{
    prevloglike = loglike
    # max step
    if(providedFit){
      updated_params = skewtMixMaxStep3comp(x, posProbs, negProbs, skewtFit)
    }
    else{
      updated_params = skewtMixMaxStep3comp(x, posProbs, negProbs, skewtFit = NULL)
    }
    pqPos = updated_params$pqPos
    pqNeg = updated_params$pqNeg
    muPos = updated_params$muPos
    muNeg = updated_params$muNeg
    sigmaPos = updated_params$sigmaPos
    sigmaNeg = updated_params$sigmaNeg
    skewtFit = updated_params$skewtFit
    # expectation step
    updated_expectations = skewtMixExpectationStep3comp(x, skewtFit, pqPos, pqNeg,
                                                        muPos, muNeg, sigmaPos, sigmaNeg)
    posProbs = updated_expectations$posProbs
    negProbs = updated_expectations$negProbs

    loglike = skewt3compLogLike(x, skewtFit, pqPos, pqNeg,
                                muPos, muNeg, sigmaPos, sigmaNeg)
    iter = iter + 1
    if(VERBOSE){
      cat("iter = ", iter, "\n",
          "prevloglike = ", prevloglike, "\n",
          "loglike = ", loglike, "\n",
          "pqPos = ", pqPos, "\n",
          "pqNeg = ", pqNeg, "\n",
          "muPos = ", muPos, "\n",
          "muNeg = ", muNeg, "\n",
          "sigmaPos = ", sigmaPos, "\n",
          "sigmaNeg = ", sigmaNeg, "\n")
    }
    if(loglike - prevloglike < tol | iter > max_iter){
      if(VERBOSE){
        cat("stop after iteration ", iter, "\n")
      }
      break
    }
  }
  return(list(posProbs = posProbs,
              negProbs = negProbs,
              skewtFit = skewtFit,
              pqPos = pqPos, pqNeg = pqNeg,
              muPos = muPos, muNeg = muNeg,
              sigmaPos = sigmaPos, sigmaNeg = sigmaNeg))
}



fitNegCtrl <- function(neg.ctrl, VERBOSE = FALSE){
  stopifnot(length(neg.ctrl) > maxDegree)
  if(VERBOSE){
    cat("negCtrl = ", head(neg.ctrl), "\n")
  }
  negCtrlFit = sn::st.mple(y = negCtrl)

  return(list(coefficients = lindsey.fit$coefficients,
              log_norm_factor = log(N) + log(d)))
}

setBimodalParams <- function(mu = -4,
                             sigma = 1,
                             pq = 0.1){
  if(length(mu) == 1){
    muPos = abs(mu)
    muNeg = -abs(mu)
  } else{
    muPos = max(mu)
    stopifnot(muPos > 0)
    muNeg = min(mu)
    stopifnot(muNeg < 0)
  }
  if(length(sigma) == 1){
    sigmaPos = sigma
    sigmaNeg = sigma
  }  else{
    sigmaPos = sigma[which.max(mu)]
    sigmaNeg = sigma[which.min(mu)]
  }
  if(length(pq) == 1){
    pqPos = pq/2
    pqNeg = pq/2
  } else{
    pqPos = pq[which.max(mu)]
    pqNeg = pq[which.min(mu)]
  }
  return(list(pqPos = pqPos,
              pqNeg = pqNeg,
              muPos = muPos,
              muNeg = muNeg,
              sigmaPos = sigmaPos,
              sigmaNeg = sigmaNeg))
}

logL <- function(p, mu, sigma, x, negLike){
  f1 = dnorm(x, mean = mu, sd = sigma)
  mixtureLike = p*f1 + (1 - p)*negLike
  return(sum(log(mixtureLike)))
}

logL_p_deriv <-function(p, mu, sigma, x, negLike){
  f1 = dnorm(x, mean = mu, sd = sigma)
  mixtureLike = p*f1 + (1 - p)*negLike
  return(sum((mixtureLike^(-1))*(f1 - negLike)))
}

logL_mu_deriv <-function(p, mu, sigma, x, negLike){
  f1 = dnorm(x, mean = mu, sd = sigma)
  mixtureLike = p*f1 + (1 - p)*negLike
  return(sum((mixtureLike^(-1))*(p*f1*(x - mu)/sigma^2)))
}

logL_sigma_deriv <-function(p, mu, sigma, x, negLike){
  f1 = dnorm(x, mean = mu, sd = sigma)
  mixtureLike = p*f1 + (1 - p)*negLike
  return(sum((mixtureLike^(-1))*(-p*f1/sigma + p*f1*((x - mu)^2)/sigma^3)))
}

f <-function(x, log2fc, negLike){
  p = x[1]
  mu = x[2]
  sigma = x[3]
  return(-logL(p, mu, sigma, log2fc, negLike))
}

f_grad <-function(x, log2fc, negLike){
  p = x[1]
  mu = x[2]
  sigma = x[3]
  return(c(-logL_p_deriv(p, mu, sigma, log2fc, negLike),
           -logL_mu_deriv(p, mu, sigma, log2fc, negLike),
           -logL_sigma_deriv(p, mu, sigma, log2fc, negLike)))
}


#' CRISPhieRmix
#'
#' a hierarchical mixture model for analysing large-scale CRISPRi/a pooled screen
#'
#' @param x log2 fold changes of guides targeting genes (required)
#' @param geneIds gene ids corresponding to x (required)
#' @param negCtrl log2 fold changes of negative control guides
#' @param max_iter maximum number of iterations for EM algorithm, default = 100
#' @param tol tolerance for convergence of EM algorithm, default = 1e-10
#' @param pq initial value of p*q, default = 0.1
#' @param mu initial value of mu for the interesting genes, default = -4
#' @param sigma initial value of sigma for the interesting genes, default = 1
#' @param nMesh the number of points to use in numerical integration of posterior probabilities, default = 100
#' @param BIMODAL boolean variable to fit a bimodal alternative distribution for the case when both directions are of interest
#' @param VERBOSE boolean variable for VERBOSE mode, default = FALSE
#' @param PLOT boolean variable to produce plots, default = FALSE
#' @param screenType acceptable options are "GOF" for gain of function screens (mu > 0) or "LOF" for loss of function screens, default = "LOF"
#' @return a list containing genes, the corresponding posterior probabilities of being non-null,
#' and the mixture fit
#' \subsection{(return)}{
#'   \describe{
#'     \item{genes}{vector of gene names}
#'     \item{locfdr}{posterior null probabilites of genes}
#'     \item{genePosteriors}{posterior non-null probabilities of genes}
#'     \item{FDR}{estimated global FDR of genes}
#'     \item{mixFit}{a list containing the estimated mixture fit}
#'   }
#' }
#'
#' @author Timothy Daley, \email{tdaley@stanford.edu}
#'
#' @examples
#' Rosenbluh2017CRISPRi.sim.DESeq.log2fc.CRISPhieRmix =
#' CRISPhieRmix(x = Rosenbluh2017CRISPRiSim$x, geneIds = Rosenbluh2017CRISPRiSim$geneIds,
#' negCtrl = Rosenbluh2017CRISPRiSim$negCtrl, mu = -2, sigma = 0.5, nMesh = 200)
#'
#' @export
CRISPhieRmix <- function(x, geneIds, negCtrl = NULL,
                         max_iter = 100, tol = 1e-10,
                         pq = 0.1, mu = -4, sigma = 1,
                         nMesh = 100,  BIMODAL = FALSE,
                         VERBOSE = FALSE, PLOT = FALSE,
                         screenType = "GOF"){
  # need to make sure the order of genes is the same, but remove levels with zero counts
  geneCounts = table(geneIds)
  genes = names(geneCounts)[which(geneCounts > 0)]
  geneIds = factor(geneIds, levels = genes)

  if(!is.null(negCtrl)){
    negCtrlFit = sn::st.mple(y = negCtrl)
    if(PLOT){
      s = seq(from = min(x), to = max(x), length = 101)
      hist(negCtrl, breaks = 80, probability = TRUE, xlim = c(min(x), max(x)), main = "negative control fit")
      lines(s, sn::dst(s, dp = negCtrlFit$dp), col = "red", lwd  = 2, lty = 2)
    }
    if(VERBOSE){
      cat("fit negative control distributions \n")
    }
    if(BIMODAL){
      if(VERBOSE){
        cat("3 groups with negative control \n")
      }
      params = setBimodalParams(mu, sigma, pq)
      if(VERBOSE){
        cat("mu0 = ", params$muPos, ", ", params$muNeg, "\n")
        cat("sigma0 = ", params$sigmaPos, ", ", params$sigmaNeg, "\n")
        cat("pq0 = ", params$pqPos, ", ", params$pqNeg, "\n")
        cat("fitting skewt mix\n")
      }
      skewtMix = skewtEM3comp(x, skewtFit = negCtrlFit, max_iter = max_iter, tol = tol,
                              pqPos = params$pqPos, pqNeg = params$pqNeg,
                              muPos = params$muPos, muNeg = params$muNeg,
                              sigmaPos = params$sigmaPos, sigmaNeg = params$sigmaNeg,
                              VERBOSE = FALSE)
      if(VERBOSE){
        cat("mu = ", skewtMix$muNeg, ", ", skewtMix$muPos, "\n")
        cat("sigma = ", skewtMix$sigmaNeg, ", ", skewtMix$sigmaPos, "\n")
        cat("pq = ", skewtMix$pqNeg, ", ", skewtMix$pqPos, "\n")
      }

      if(PLOT){
        if(VERBOSE){
          cat("plotting \n")
        }
       b = seq(from = min(x) - 0.1, to = max(x) + 0.1, length = 101)
        hist(x, breaks = b, probability = TRUE, main = "mixture fit to observations")
        lines(b, skewtMix$pqPos*dnorm(b, skewtMix$muPos, skewtMix$sigmaPos) + skewtMix$pqNeg*dnorm(b, skewtMix$muNeg, skewtMix$sigmaNeg),
              lwd = 2, col = "darkgreen")
        lines(b, (1 - skewtMix$pqPos - skewtMix$pqNeg)*sn::dst(b, dp = negCtrlFit$dp), col = "red", lwd  = 2)
        lines(b, skewtMix$pqPos*dnorm(b, skewtMix$muPos, skewtMix$sigmaPos) + skewtMix$pqNeg*dnorm(b, skewtMix$muNeg, skewtMix$sigmaNeg) +
                (1 - skewtMix$pqPos - skewtMix$pqNeg)*sn::dst(b, dp = negCtrlFit$dp), col = "darkviolet", lty = 2, lwd = 2)
      }
      if(VERBOSE){
        cat("computing gene level posteriors \n")
      }
      log_null_guide_probs = sn::dst(x, dp = negCtrlFit$dp, log = TRUE)
      log_pos_guide_probs = dnorm(x, mean = skewtMix$muPos, sd = skewtMix$sigmaPos, log = TRUE)
      log_neg_guide_probs = dnorm(x, mean = skewtMix$muNeg, sd = skewtMix$sigmaNeg, log = TRUE)
      if(VERBOSE){
        cat("marginalizing guide variability \n")
      }
      posGenePosteriors = gaussQuadGeneExpectation3Groups(x = x, geneIds = geneIds,
                                                          log_pos_guide_probs = log_pos_guide_probs,
                                                          log_neg_guide_probs = log_neg_guide_probs,
                                                          log_null_guide_probs = log_null_guide_probs,
                                                          tau_pos = skewtMix$pqPos,
                                                          tau_neg = skewtMix$pqNeg,
                                                          nMesh = nMesh)
      # can use the same function, just switch positive and negative groups
      negGenePosteriors = gaussQuadGeneExpectation3Groups(x = x, geneIds = geneIds,
                                                          log_pos_guide_probs = log_neg_guide_probs,
                                                          log_neg_guide_probs = log_pos_guide_probs,
                                                          log_null_guide_probs = log_null_guide_probs,
                                                          tau_pos = skewtMix$pqNeg,
                                                          tau_neg = skewtMix$pqPos,
                                                          nMesh = nMesh)
      if(VERBOSE){
        cat("computing FDRs \n")
      }
      negLocFDR = 1 - negGenePosteriors
      negFDR = sapply(negLocFDR, function(x) mean(negLocFDR[which(negLocFDR <= x)]))
      posLocFDR = 1 - posGenePosteriors
      posFDR = sapply(posLocFDR, function(x) mean(posLocFDR[which(posLocFDR <= x)]))

      locfdr = sapply(1 - posGenePosteriors - negGenePosteriors, function(y) max(0, y))
      mixFit = list(genes = levels(geneIds),
                    locfdr = locfdr,
                    posGenePosteriors = posGenePosteriors,
                    negGenePosteriors = negGenePosteriors,
                    negFDR = negFDR,
                    posFDR = posFDR,
                    FDR = sapply(locfdr, function(x) mean(locfdr[which(locfdr <= x)])),
                    mixFit = skewtMix)

    } else{
      # two groups
      stopifnot(length(mu) == 1)
      if(VERBOSE){
        cat("2 groups \n")
      }
      if(!(screenType == "LOF" | screenType == "GOF")){
        cat("screenType unknown, acceptable options are \"GOF\" and \"LOF\" (default)\n")
      }
      stopifnot(screenType == "LOF" | screenType == "GOF")
      if(screenType == "LOF"){
        lowerbounds = c(0, -Inf, 0)
        upperbounds = c(1, 0, Inf)
        mu = -abs(mu)
      }
      else if(screenType == "GOF"){
        lowerbounds = c(0, 0, 0)
        upperbounds = c(1, Inf, Inf)
        mu = abs(mu)
      }
      opts = list("algorithm" = "NLOPT_LD_LBFGS",
                  "xtol" = 1e-8,
                  "maxeval" = 10000)
      # non-linear optimization
      params_guess = c(pq, mu, sigma)
      negLike = sn::dst(x, dp = negCtrlFit$dp)

      res = nloptr::nloptr(x0 = params_guess, eval_f = f, eval_grad_f = f_grad, opts = opts, lb = lowerbounds, ub = upperbounds, log2fc = x, negLike = negLike)
      skewtMix = list(pq = res$solution[1], mu = res$solution[2], sigma = res$solution[3], skewtFit = negCtrlFit, posProbs = skewtMixExpectationStep2comp(x, skewtFit = negCtrlFit, mu = res$solution[2], sigma = res$solution[3], pq = res$solution[1]))

      if(VERBOSE){
        cat("converged \n")
        cat("mu = ", skewtMix$mu, "\n")
        cat("sigma = ", skewtMix$sigma, "\n")
        cat("pq = ", skewtMix$pq, "\n")
      }
      if(PLOT){
        b = seq(from = min(x) - 0.1, to = max(x) + 0.1, length = 101)
        hist(x, breaks = b, probability = TRUE, main = "mixture fit to observations")
        lines(b, skewtMix$pq*dnorm(b, skewtMix$mu, skewtMix$sigma),
              lwd = 2, col = "darkgreen")
        lines(b, (1 - skewtMix$pq)*sn::dst(b, dp = negCtrlFit$dp), col = "red", lwd  = 2)
        lines(b, skewtMix$pq*dnorm(b, skewtMix$mu, skewtMix$sigma) + (1 - skewtMix$pq)*sn::dst(b, dp = negCtrlFit$dp), col = "darkviolet", lty = 2, lwd = 2)
      }

      log_null_guide_probs = sn::dst(x, dp = negCtrlFit$dp, log = TRUE)
      log_alt_guide_probs = dnorm(x, mean = skewtMix$mu, sd = skewtMix$sigma, log = TRUE)
      genePosteriors = gaussQuadGeneExpectation2Groups(x = x, geneIds = geneIds,
                                                       log_alt_guide_probs = log_alt_guide_probs,
                                                       log_null_guide_probs = log_null_guide_probs,
                                                       tau = skewtMix$pq, nMesh = 100)
      locfdr = sapply(1 - genePosteriors, function(y) max(0, y)) # sometimes returns -1e-16
      mixFit = list(genes = levels(geneIds),
                    locfdr = locfdr,
                    genePosteriors = genePosteriors,
                    FDR = sapply(locfdr, function(x) mean(locfdr[which(locfdr <= x)])),
                    mixFit = skewtMix)
    }
  }
  else{

    if(VERBOSE){
      cat("no negative controls provided, fitting hierarchical normal model \n")
    }
    require(mixtools)
    if(BIMODAL){
      if(VERBOSE){
        cat("3 groups without negative control \n")
        cat("mu = ", mu, "\n")
        cat("sigma = ", sigma, "\n")
        cat("pq = ", pq, "\n")
      }
      params = setBimodalParams(mu = mu, sigma = sigma, pq = pq)

      normalMixFit = mixtools::normalmixEM(x, k = 3, mu = c(0, params$muPos, params$muNeg),
                                           sigma = c(1, params$sigmaPos, params$sigmaNeg),
                                           mean.constr = c(0, "a", "-b"))

      if(PLOT){
        plot(normalMixFit, density = TRUE, whichplots = 2)
      }
      log_null_guide_probs = dnorm(x, mean = normalMixFit[["mu"]][[1]], sd = normalMixFit[["sigma"]][[1]], log = TRUE)
      log_pos_guide_probs = dnorm(x, mean = normalMixFit[["mu"]][[2]], sd = normalMixFit[["sigma"]][[2]], log = TRUE)
      log_neg_guide_probs = dnorm(x, mean = normalMixFit[["mu"]][[3]], sd = normalMixFit[["sigma"]][[3]], log = TRUE)
      posGenePosteriors = gaussQuadGeneExpectation3Groups(x = x, geneIds = geneIds,
                                                          log_pos_guide_probs = log_pos_guide_probs,
                                                          log_neg_guide_probs = log_neg_guide_probs,
                                                          log_null_guide_probs = log_null_guide_probs,
                                                          tau_pos = normalMixFit$lambda[2],
                                                          tau_neg = normalMixFit$lambda[3],
                                                          nMesh = nMesh)
      # can use the same function, just switch positive and negative groups
      negGenePosteriors = gaussQuadGeneExpectation3Groups(x = x, geneIds = geneIds,
                                                          log_pos_guide_probs = log_neg_guide_probs,
                                                          log_neg_guide_probs = log_pos_guide_probs,
                                                          log_null_guide_probs = log_null_guide_probs,
                                                          tau_pos = normalMixFit$lambda[3],
                                                          tau_neg = normalMixFit$lambda[2],
                                                          nMesh = 100)
      negLocFDR = 1 - negGenePosteriors
      negFDR = sapply(negLocFDR, function(x) mean(negLocFDR[which(negLocFDR <= x)]))
      posLocFDR = 1 - posGenePosteriors
      posFDR = sapply(posLocFDR, function(x) mean(posLocFDR[which(posLocFDR <= x)]))

      locfdr = sapply(1 - posGenePosteriors - negGenePosteriors, function(y) max(0, y))
      mixFit = list(genes = levels(geneIds),
                    locfdr = locfdr,
                    posGenePosteriors = posGenePosteriors,
                    negGenePosteriors = negGenePosteriors,
                    negFDR = negFDR,
                    posFDR = posFDR,
                    FDR = sapply(locfdr, function(x) mean(locfdr[which(locfdr <= x)])),
                    mixFit = normalMixFit)

    }
    else{
      normalMixFit = mixtools::normalmixEM(x, k = 2, mu = c(0, mu),
                                         sigma = c(1, sigma))
      if(PLOT){
        plot(normalMixFit, density = TRUE, whichplots = 2)
      }
      log_alt_guide_probs = dnorm(x, mean = normalMixFit[["mu"]][[2]], sd = normalMixFit[["sigma"]][[2]], log = TRUE)
      log_null_guide_probs = dnorm(x, mean = normalMixFit[["mu"]][[1]], sd = normalMixFit[["sigma"]][[1]], log = TRUE)
      genePosteriors = gaussQuadGeneExpectation2Groups(x = x, geneIds = geneIds,
                                                       log_alt_guide_probs = log_alt_guide_probs,
                                                       log_null_guide_probs = log_null_guide_probs,
                                                       tau = normalMixFit[["lambda"]][[2]], nMesh = 100)
      locfdr = sapply(1 - genePosteriors, function(y) max(0, y)) # sometimes returns -1e-16

      mixFit = list(genes = levels(geneIds),
                    locfdr = locfdr,
                    geneScores = genePosteriors,
                    FDR = sapply(locfdr, function(x) mean(locfdr[which(locfdr <= x)])),
                    mixFit = normalMixFit)
    }
  }
  return(mixFit)
}




