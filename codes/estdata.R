library(tidyverse)
library(stringr)
library(lubridate)
library(rebus)


#rm(list = ls()[!(ls() == 'IMFenvs')])

### Dataprep ###

#Load data and clean up some mess
macrodata <- read_rds(file.path('data', 'macrodata.rds')) %>% 
  mutate(country = ifelse(country == 'Chech Repbublic', 'Czech Republic', country))
shocks <- read_rds(file.path('data', 'gta_shocks.rds')) %>% 
  mutate(country_imp = ifelse(country_imp == 'Czechia', 'Czech Republic', country_imp),
         country_aff = ifelse(country_aff == 'Czechia', 'Czech Republic', country_aff),
         country_imp = ifelse(country_imp == 'Republic of Korea', 'South Korea', country_imp),
         country_aff = ifelse(country_aff == 'Republic of Korea', 'South Korea', country_aff),
         country_imp = ifelse(country_imp == 'Chinese Taipei', 'Taiwan', country_imp),
         country_aff = ifelse(country_aff == 'Chinese Taipei', 'Taiwan', country_aff),
         country_imp = ifelse(country_imp == 'United Kingdom', 'UK', country_imp),
         country_aff = ifelse(country_aff == 'United Kingdom', 'UK', country_aff),
         country_imp = ifelse(country_imp == 'United States of America', 'US', country_imp),
         country_aff = ifelse(country_aff == 'United States of America', 'US', country_aff))

#Annualized growth and inflation rates
macrodata <- macrodata %>% 
  arrange(country, date) %>% 
  #mutate(ip = log(ip),
  #       pi = log(pi),
  #       e = log(e),
  #       r = log(100+r)) %>% 
  group_by(country) %>% 
  #mutate(ip = ip - lag(ip, n = 12),
  #       pi = pi - lag(pi, n = 12)) %>% 
  drop_na() %>% 
  ungroup()

#Set range
start <- max(
  min(shocks$date),
  min(macrodata$date)
)
end <- min(
  max(shocks$date),
  max(macrodata$date)
)

macrodata <- macrodata %>% 
  filter(date >= start,
         date <= end)

shocks <- shocks %>% 
  filter(date >= start,
         date <= end)


#Country FE - demean variables 
macrodata <- macrodata %>% 
  group_by(country) %>% 
  mutate(across(-date, ~.x - mean(.x))) %>% 
  ungroup() 


### Functions ###

# Create the function to get modes where non-weighted shocks need to be aggregated
getmode <- function(v) {
  uniqv <- unique(v)
  uniqv[which.max(tabulate(match(v, uniqv)))]
}

#Create the target variables at horizon h
genlhs <- function(data, var, h){
  
  require(tidyverse)
  
  suppressMessages(
    data <- data %>% 
      group_by(country) %>% 
      select(date, sym(var)) %>% 
      mutate(
        #h lead of lhs values
        map_dfc(seq(h), ~ lead(!!sym(var), n = .x)) %>%
          set_names(paste('lead',seq(h),'_', var, sep = ''))
        
      ) %>% 
      ungroup() %>% 
      select(country, date, starts_with('lead'))
  )
  
  data
}

#Create the control variables at lags up to k
genrhs_macro <- function(data, var, k){
  
  require(tidyverse)
  
  suppressMessages(
    data <- data %>% 
      group_by(country) %>% 
      select(date, sym(var)) %>% 
      mutate(
        #k lags of control
        map_dfc(seq(k), ~ lag(!!sym(var), n = .x)) %>%
          set_names(paste('lag',seq(k),'_', var, sep = ''))
      ) %>% 
      ungroup() %>% 
      select(country, date, starts_with('lag'))
  )
  
  data
}

#Create the shock variables 
genrhs_shock <- function(shocks, var, k){
  require(tidyverse)
  
  suppressMessages(
    data <- shocks %>% 
      group_by_at(vars(-contains('shock'), -contains('lead'), -contains('lag'), -date)) %>% 
      mutate(
        #k lags of control
        map_dfc(seq(k), ~ lag(!!sym(var), n = .x)) %>%
          set_names(paste('lag',seq(k),'_', var, sep = ''))
      ) %>% 
      ungroup() 
  )
  
  data
}

#Add all shock variations
add_allshocks <- function(shocks){
  
  require(tidyverse)
  
  shocks_all <- NULL  
  shocks_funs <- NULL
  
  #Binary type shocks - global
  
  shocks_all[['base']] <- shocks %>% 
    filter(db == 'main') %>% 
    group_by(date) %>% 
    summarize(shock = getmode(shock_base)) #%>% 
  shocks_funs[['base']] <- function(shocks, k) genrhs_shock(shocks, 'shock', k)
  
  shocks_all[['sign_asym']] <- shocks %>% 
    filter(db == 'main') %>% 
    group_by(date, gta_eval) %>% 
    summarize(shock = getmode(shock_base)) %>% 
    spread(gta_eval, shock) %>% 
    rename(shock_pos = Green,
           shock_neg = Red) %>% 
    mutate(across(starts_with('shock'), ~abs(.x)))#%>% 
  shocks_funs[['sign_asym']] <- function(shocks, k) genrhs_shock(shocks, 'shock_neg', k) %>% genrhs_shock('shock_pos', k)
  
  shocks_all[['perm_vs_trans']] <- shocks %>% 
    filter(db == 'main') %>% 
    group_by(date) %>% 
    summarize(shock_trans = getmode(shock_trans),
              shock_perm = getmode(shock_perm)) #%>% 
  shocks_funs[['perm_vs_trans']] <- function(shocks, k) genrhs_shock(shocks, 'shock_trans', k) %>% genrhs_shock('shock_perm', k)
  
  
  #Weighted shocks - global
  
  shocks_all[['base_w']] <- shocks %>% 
    filter(db == 'main') %>% 
    group_by(date) %>% 
    summarize(shock = sum(shock_base)) #%>% 
  shocks_funs[['base_w']] <- function(shocks, k) genrhs_shock(shocks, 'shock', k)
  
  shocks_all[['sign_asym_w']] <- shocks %>% 
    filter(db == 'main') %>% 
    group_by(date, gta_eval) %>% 
    summarize(shock = sum(shock_base)) %>% 
    spread(gta_eval, shock) %>% 
    rename(shock_pos = Green,
           shock_neg = Red) %>% 
    mutate(across(starts_with('shock'), ~abs(.x)))#%>%
  shocks_funs[['sign_asym_w']] <- function(shocks, k) genrhs_shock(shocks, 'shock_neg', k) %>% genrhs_shock('shock_pos', k)
  
  shocks_all[['perm_vs_trans_w']] <- shocks %>% 
    filter(db == 'main') %>% 
    group_by(date) %>% 
    summarize(shock_trans = sum(shock_trans),
              shock_perm = sum(shock_perm)) #%>% 
  shocks_funs[['perm_vs_trans_w']] <- function(shocks, k) genrhs_shock(shocks, 'shock_trans', k) %>% genrhs_shock('shock_perm', k)
  
  
  #Weighted shocks - imposer country
  
  shocks_all[['base_imp']] <- shocks %>% 
    filter(db == 'main') %>% 
    group_by(date, country_imp) %>% 
    summarize(shock = sum(shock_base)) %>%
    rename(country = country_imp)
  shocks_funs[['base_imp']] <- function(shocks, k) genrhs_shock(shocks, 'shock', k)
  
  shocks_all[['sign_asym_imp']] <- shocks %>% 
    filter(db == 'main') %>% 
    group_by(date, gta_eval, country_imp) %>% 
    summarize(shock = sum(shock_base)) %>% 
    spread(gta_eval, shock) %>% 
    rename(shock_pos = Green,
           shock_neg = Red)  %>%
    rename(country = country_imp) %>% 
    mutate(across(starts_with('shock'), ~abs(.x)))#%>%
  shocks_funs[['sign_asym_imp']] <- function(shocks, k) genrhs_shock(shocks, 'shock_neg', k) %>% genrhs_shock('shock_pos', k)
  
  shocks_all[['perm_vs_trans_imp']] <- shocks %>% 
    filter(db == 'main') %>% 
    group_by(date, country_imp) %>% 
    summarize(shock_trans = sum(shock_trans),
              shock_perm = sum(shock_perm))  %>%
    rename(country = country_imp)
  shocks_funs[['perm_vs_trans_imp']] <- function(shocks, k) genrhs_shock(shocks, 'shock_trans', k) %>% genrhs_shock('shock_perm', k) 
  
  
  #Weighted shocks - affected country
  
  shocks_all[['base_aff']] <- shocks %>% 
    filter(db == 'main') %>% 
    group_by(date, country_aff) %>% 
    summarize(shock = sum(shock_base))  %>%
    rename(country = country_aff)
  shocks_funs[['base_aff']] <- function(shocks, k) genrhs_shock(shocks, 'shock', k)
  
  shocks_all[['sign_asym_aff']] <- shocks %>% 
    filter(db == 'main') %>% 
    group_by(date, gta_eval, country_aff) %>% 
    summarize(shock = sum(shock_base)) %>% 
    spread(gta_eval, shock) %>% 
    rename(shock_pos = Green,
           shock_neg = Red) %>%
    rename(country = country_aff) %>% 
    mutate(across(starts_with('shock'), ~abs(.x)))#%>%
  shocks_funs[['sign_asym_aff']] <- function(shocks, k) genrhs_shock(shocks, 'shock_neg', k) %>% genrhs_shock('shock_pos', k)
  
  shocks_all[['perm_vs_trans_aff']] <- shocks %>% 
    filter(db == 'main') %>% 
    group_by(date, country_aff) %>% 
    summarize(shock_trans = sum(shock_trans),
              shock_perm = sum(shock_perm)) %>%
    rename(country = country_aff) 
  shocks_funs[['perm_vs_trans_aff']] <- function(shocks, k) genrhs_shock(shocks, 'shock_trans', k) %>% genrhs_shock('shock_perm', k) 
  
  list(shocks_all, shocks_funs)
  
}

#Combine lhs and rhs macro variables
genvars <- function(data, k, h){
  
  vars <- names(data)[!str_detect(names(data), or('country', 'date'))] 
  
  dlist <- NULL
  for(i in 1:length(vars)){
    lhs <- genlhs(data = data,
                  var = vars[i],
                  h = h)
    
    rhs <- genrhs_macro(data = data,
                        var = vars[i],
                        k = k)
    suppressMessages(joined <- left_join(rhs, lhs))
    dlist[[i]] <- joined
  }
  
  names(dlist) <- vars
  
  dlist
}

#Combine lhs and rhs macro variables
genvars2 <- function(data, shocks, k, h){
  
  macrodata <- data
  vars <- names(macrodata)[!str_detect(names(macrodata), or('country', 'date'))] 
  suppressMessages(shocks_all <- add_allshocks(shocks) )
  k <- k
  h <- h
  
  
  macrovars <- genvars(macrodata,
                       k,
                       h)
  
  temp <- NULL
  out <- NULL
  for(j in 1:length(shocks_all[[1]])){
    genfun <- shocks_all[[2]][[j]]
    for(i in 1:length(macrovars)){
      temp[[i]] <- macrovars[[i]] %>% left_join(shocks_all[[1]][[j]]) %>% 
        mutate(across(starts_with('shock'), ~replace_na(.x, 0))) %>% 
        genfun(k = k)
    }
    out[[j]] <- temp
    names(out[[j]]) <- vars
  }
  
  names(out) <- names(shocks_all[[1]])
  
  out
  
}


estdata <- genvars2(macrodata,
                    shocks,
                    12,
                    61)

saveRDS(estdata, file.path('data', 'estdata.rds'))