#!/usr/bin/perl
#
# @File geekerBotV2.pm
# @Author N
# @Created Aug 18, 2016 10:10:45 PM
#


package geekerBotV2;
use DBI;
use Data::Dumper;
use Digest::SHA qw(hmac_sha512_hex);
use LWP::UserAgent;  
use JSON;
print "Running in: $^O\n";
if ($^O =~ /^Win/i)
{ use Win32::Console::ANSI} #for windows }
else
{ use Term::ANSIColor;} #for linux

    
sub new
{
    my $class = shift;
    my $self = {
        dbHost => 'localhost',
        dbName => 'geekerV2',
        dbUser => 'geeker',
        dbPass => shift,        
        bittrexApiSecret => '',
        soldArt => '',
        buyArt=> '',
        sellArt=> '',
        profitArt=> '',        
        currentCycle => 0,
        btcPrice => 0,        
        availableBtc => 0,        
        delayBuysCyclesLeft => 0,
        coinMetricsTimeRange => 2,
        investPercent => 100,
        retrySellMax => 2,
        retrySells => 0,
        delayBuyCyclesRemaining => 0,
        delayBuyUntilMoreThan => '0.00062500',
	payoutPercentage => 0.10,
	totalPayout => 0,
	
    };
    bless $self, $class;
    print color('bold yellow');
    printSellArt();
    print "GeekerV2 Starting...\n\n";
    print color('reset');
    return $self;
}

sub run {
    my ($self) = @_;
    if ( !defined($self->{bittrexApiKey}) || $self->{bittrexApiKey} eq '' ) {
        print "|-- Fetching Api Key... *Preventing API and SIGNATURE Errors* *Experimental* \n";
        $self->{bittrexApiKey} = $self->getApiKey();
        #print Dumper($self);die();        
    }
    $self->fetchBalances(); # Once At Beginning and...
    $self->getTotalPayout(); #once At Beginning
	print "|--- Total Reserved Bitcoin: " .$self{totalPayout}."\n";
    $self->btcPriceCheck();
    $self->priceCheck();
    select(undef,undef,undef,1); # pause half second
    my $chooserDB = $self->getDb();
    my $choice = $chooserDB->prepare("SELECT * from currencies WHERE tradeMe=1 or priceCheck=1");
    $choice->execute();
    while ( my $ch = $choice->fetchrow_hashref() ) {
        $self->fetchOrderHistory($ch->{coin});        
        select(undef,undef,undef,1); # pause quarter second
    }        
    $choice = $chooserDB->prepare("SELECT * from currencies WHERE tradeMe=1");
    $choice->execute();
    while ( my $ch = $choice->fetchrow_hashref() ) {
        $self->fetchOpenOrders($ch->{coin});        
        select(undef,undef,undef,1); # pause quarter second
    }
    
    select(undef,undef,undef,1); # pause quarter second
    $self->populateCoinMetrics();   # All Coins at once, only do this once, no api calls, only Db action
    
    $choice = $chooserDB->prepare("SELECT * from currencies WHERE tradeMe=1 ORDER BY coin ASC");
    $choice->execute();
    while ( my $ch = $choice->fetchrow_hashref() ) {
        $self->alt_findProfitAndBuy($ch->{coin});        
        select(undef,undef,undef,1); # pause quarter second
    }
    
    
    #FETCH UPDATED HISTORY
    $choice = $chooserDB->prepare("SELECT * from currencies WHERE tradeMe=1 or priceCheck=1");
    $choice->execute();
    while ( my $ch = $choice->fetchrow_hashref() ) {
        $self->fetchOrderHistory($ch->{coin});        
        select(undef,undef,undef,1); # pause quarter second
    }        
    $choice->finish();
    $chooserDB->do("DELETE from totalBtcHistory where usdAmount = 0 or btcAmount = 0");    
    $chooserDB->disconnect();
    
    # Sync ALL AUTOTRADE ORDER DETAILS (correct profit and REMAINING!!)
    $self->syncAllAutoTrades();

    # check autoTrades (all coins)
    $self->autoResolveAutoTrades();    
    $self->updateAutoTradeOrders(); # before any trimming, this updates remaining order into autoTrade Table
                                    # dont forget to add something to trimOldBuys (already there) and dragDownSells
    
    $self->trimOldBuys(5);
    $self->altDragDownSells(2);
    select(undef,undef,undef,1); # pause 1 second
    
    # Sync ALL AUTOTRADE ORDER DETAILS (correct profit and REMAINING!!)
    # $self->syncAllAutoTrades();

    
    # $self->tradeDownToZero(); #TODO
    $self->fetchBalances(); # ...and Once At The End
    
    # Then do more shit
    $self->updatetotalBtcHistory();
    
    $self->{currentCycle}++;
    if ( $self->{delayBuyCyclesRemaining} > 0 ) {
        $self->{delayBuyCyclesRemaining}--;
    }
}

sub syncAllAutoTrades {
    # Syncs what we believe with what the Market Exchange Server knows about each autoTrade order.
    my ($self) = @_;
    print "\n|-- ".localtime()." \n";
    print "|-- syncAllAutoTrades \n";
    my $chooserDB = $self->getDb();
    my $fetchAt = $chooserDB->prepare("SELECT * FROM autoTrades where resolved = 0 AND sold = 0");
    $fetchAt->execute();
    while ( my $aTrade = $fetchAt->fetchrow_hashref() ) {
        my $detail = $self->fetchOrderDetails($aTrade->{uuid});
        #print '-- ATRADE REMAINING: ' . $self->deci($aTrade->{remaining}) . "\n"; 
        #print '-- Fetched REMAINING: ' . $self->deci($detail->{QuantityRemaining}) . "\n"; 
        if ( $self->deci($aTrade->{remaining}) != $self->deci($detail->{QuantityRemaining}) && (!($self->nullVar($detail))) ) {
                if ( (!($self->nullVar($detail->{QuantityRemaining}))) ) {
                    $chooserDB->do("UPDATE autoTrades SET remaining=" . $self->deci($detail->{QuantityRemaining}) . " WHERE uuid='" . $aTrade->{uuid} ."'");                
                    #print Dumper($detail);
                    if ( $self->deci($detail->{QuantityRemaining}) != $self->deci($detail->{Quantity}) ) { print color('bold green'); }
                    print "|- Synced Remaining To: ". $self->deci($detail->{QuantityRemaining}) . " of ".$self->deci($detail->{Quantity})." $aTrade->{coin} $aTrade->{type} [Local: ".$self->deci($aTrade->{remaining})." _vs_ Server: ".$self->deci($detail->{QuantityRemaining})."]\n"; 
                    if ( $self->deci($detail->{QuantityRemaining}) != $self->deci($detail->{Quantity}) ) { print color('reset'); }
                }
        } else { print "|- NOSYNC ". $self->deci($detail->{QuantityRemaining}) . " of ". $self->deci($aTrade->{amount})." $aTrade->{coin} $aTrade->{type} [Local: ".$self->deci($aTrade->{remaining})." _vs_ Server: ".$self->deci($detail->{QuantityRemaining})."]\n"; }


        #print $self->deci($detail->{QuantityRemaining}) . " - ";
        #print Dumper($detail);
        #print "Quant => ".$self->deci($detail->{Quantity}) . " | ";
        select(undef,undef,undef,1); # pause
    }
    $fetchAt->finish();
    $chooserDB->disconnect();
    print "|-- End syncAllAutoTrades() \n";
}

sub initDbTables {
    my ($self) = @_;
    # Check each required table, create if they dont exist
    if ( $self->doesTableExist("accounts") == 0 ) {
        print "|-- Table 'accounts' Does Not Exist!\n";
        $self->createAccountsDbTable();
        die("You MUST insert your account(api details,etc) MANUALLY within Database\n");
    }
    if ( $self->doesTableExist("currencies") == 0 ) {
        print "|-- Table 'currencies' Does Not Exist!\n";
        $self->createCurrenciesDbTable();
    }
    if ( $self->doesTableExist("orderHistory") == 0 ) {
        print "|-- Table 'orderHistory' Does Not Exist!\n";
        $self->createOrderHistoryDbTable();
    }
    if ( $self->doesTableExist("autoTrades") == 0 ) {
        print "|-- Table 'autoTrades' Does Not Exist!\n";
        $self->createAutoTradesDbTable();
    }
    if ( $self->doesTableExist("openOrders") == 0 ) {
        print "|-- Table 'openOrders' Does Not Exist!\n";
        $self->createOpenOrdersDbTable();
    }
    if ( $self->doesTableExist("coinMetrics") == 0 ) {
        print "|-- Table 'coinMetrics' Does Not Exist!\n";
        $self->createCoinMetricsDbTable();
    }
    if ( $self->doesTableExist("btcPriceHistory") == 0 ) {
        print "|-- Table 'btcPriceHistory' Does Not Exist!\n";
        $self->createBtcPriceHistoryDbTable();
    }
    if ( $self->doesTableExist("totalBtcHistory") == 0 ) {
        print "|-- Table 'totalBtcHistory' Does Not Exist!\n";
        $self->createTotalBtcHistoryDbTable();
    }
    if ( $self->doesTableExist("altCoinPriceHistory") == 0 ) {
        print "|-- Table 'altCoinPriceHistory' Does Not Exist!\n";
        $self->createAltCoinPriceHistoryDbTable();
    }
}

##########
# Deciders
##########
sub findProfitAndBuy {       
    my ($self,$coin) = @_;
    # Question: buy @ bidPrice & Sell @ highestPrice? (with dragDowns)
    # OR
    # Question: buy @ lowestPrice & Sell @ highestPrice? (with dragDowns)
    # Hell If I Know. Lets try the first one.
    # Note: We Dont Return Anything, we buy or we dont buy
    print "\n|-- ".localtime()." \n";
    print "|-- findProfitAndBuy $coin \n";
    my $bidPrice = $self->bidCoinPrice($coin,$self->{coinMetricsTimeRange}/2);
    my $highPrice = $self->highestCoinPrice($coin,$self->{coinMetricsTimeRange}/2);
    my $howMany = $self->howManyAfford($coin,$bidPrice);
    if ( $howMany > 0 ) { print "|-- Can Afford ".$self->deci($howMany)."\n"; } else { print "|-- Can Afford ".$self->deci($howMany)."\n";return; }
    my $totalBuyPrice = ($howMany * $bidPrice);
    my $buyCommission = ($totalBuyPrice * 0.0025);
    my $totalSellPrice = ($howMany * $highPrice);
    my $sellCommission = ($totalSellPrice * 0.0025);
    my $totalCommission = ($buyCommission + $sellCommission);
    # Find The Preciouseseses
    my $sellProfit = ($totalSellPrice - $totalBuyPrice);
    my $profitAfterCommission = (($totalSellPrice - $totalBuyPrice) - $totalCommission);

    print "|-- IF Buy ".$self->deci($howMany)." $coin at ".$self->deci($bidPrice)." For ".$self->deci($totalBuyPrice)." BTC and then\n";
    print "|-- IF Sell ".$self->deci($howMany)." $coin at ".$self->deci($highPrice)." For ".$self->deci($totalSellPrice)." BTC \n";
    print "|-- Profit Before Commission will be: ".$self->deci($sellProfit)." BTC.\n";
    print "|-- Profit After Commission will be: ".$self->deci($profitAfterCommission)." BTC.\n";
    if ( $profitAfterCommission >= 0.00000100 ) {
        print "****** YES! (Actual Profit is Over 100 Satoshis) ******\n";
        if ( $howMany > 0 && $self->{availableBtc} >= $self->{delayBuyUntilMoreThan} && ( $self->{delayBuyCyclesRemaining} < 1 ) ) {
            print color('bold green');
	    print "|--- BUYING ".$self->deci($howMany)." OF $coin @ ".$self->deci($bidPrice)." FOR  ".$self->deci($totalBuyPrice). "\n";            
            print color('reset');
            $self->placeBuyOrder($coin,$howMany,$bidPrice,$highPrice,$buyCommission,$sellCommission);
        } else {
            print "|-- Not Buying ".$self->deci($howMany)." of $coin\n";
            print "|-- Buy Delay Cycles Remaining? ---> " . $self->{delayBuyCyclesRemaining} . "\n";
            print "|-- Available: $self->{availableBtc} \n|-- Buy Delay Until More Than? --> " . $self->deci($self->{delayBuyUntilMoreThan}) . "\n";
        }
    } else {
        print "###### NO! NO! NO! (Actual Profit is NOT Over 100 Satoshis) ######\n";
    }    
    # Well, thats that then...
}

sub alt_findProfitAndBuy {       
    my ($self,$coin) = @_;
    # Question: buy @ bidPrice & Sell @ highestPrice? (with dragDowns)
    # OR
    # Question: buy @ lowestPrice & Sell @ highestPrice? (with dragDowns)
    # Hell If I Know. Lets try the first one.
    # Note: We Dont Return Anything, we buy or we dont buy
    print "\n|-- ".localtime()." \n";
    print "|-- ALTERNATE findProfitAndBuy $coin \n";
    #MODIFY bidPrice by +1 satoshi for our calc (PriceIsRight Move)
    my $bidPrice = $self->deci($self->lowestCoinPrice($coin,$self->deci($self->{coinMetricsTimeRange})));
    my $highPrice = $self->highestCoinPrice($coin,$self->{coinMetricsTimeRange});
    #REPLACE highPrice with AskPrice - 1 satoshi
    my $askPrice = $self->deci($self->askCoinPrice($coin,1) );
    my $howMany = $self->howManyAfford($coin,$bidPrice);
    if ( $howMany > 0 ) { print "|-- Can Afford ".$self->deci($howMany)."\n"; } else { print "|-- Can Afford ".$self->deci($howMany)."\n";return; }
    my $totalBuyPrice = ($howMany * $bidPrice);
    my $buyCommission = ($totalBuyPrice * 0.0025);
    #my $totalSellPrice = ($howMany * $highPrice);
    my $totalSellPrice = $self->deci($howMany * $self->deci($askPrice - 0.00000001) );

    my $sellCommission = $self->deci($totalSellPrice * 0.0025);
    my $totalCommission = $self->deci($buyCommission + $sellCommission);
    # Find The Preciouseseses
    my $sellProfit = $self->deci($self->deci($totalSellPrice - $totalBuyPrice) );
    my $profitAfterCommission = $self->deci(($totalSellPrice - $totalBuyPrice) - $totalCommission);
    print "|-- IF Buy ".$self->deci($howMany)." $coin at ".$self->deci($bidPrice)." For ".$self->deci($totalBuyPrice)." BTC and then\n";
    print "|-- IF Sell ".$self->deci($howMany)." $coin at ".$self->deci($askPrice)." For ".$self->deci($totalSellPrice)." BTC \n";
    print "|-- Profit Before Commission will be: ".$self->deci($sellProfit)." BTC.\n";
    print "|-- Profit After Commission will be: ".$self->deci($profitAfterCommission)." BTC.\n";
    
    if ( $profitAfterCommission >= 0.00000100 ) {
        print "****** YES! (Actual Profit is Over 100 Satoshis) ******\n";
        if ( $howMany > 0 && $self->deci($self->{availableBtc}) >= $self->{delayBuyUntilMoreThan} && ( $self->{delayBuyCyclesRemaining} < 1 ) ) {
            print color('bold green');
	    print "|--- BUYING ".$self->deci($howMany)." OF $coin @ ".$self->deci($bidPrice)." FOR  ".$self->deci($totalBuyPrice). "\n";            
            print color('reset');
            $self->placeBuyOrder($coin,$howMany,$bidPrice,$askPrice,$buyCommission,$sellCommission);
        } else {
            print "|-- Not Buying ".$self->deci($howMany)." of $coin\n";
            print "|-- Buy Delay Cycles Remaining? ---> " . $self->{delayBuyCyclesRemaining} . "\n";
            print "|-- Available: $self->{availableBtc} \n|-- Buy Delay Until More Than? --> " . $self->deci($self->{delayBuyUntilMoreThan}) . "\n";
        }
    } else {
        print "###### NO! NO! NO! (Actual Profit is NOT Over 100 Satoshis) ######\n";
    }    
    # Well, thats that then...
}

sub howManyAfford {
    my ($self,$coin,$coinPrice) = @_;   
    my $availableBalance = $self->{availableBtc};             
    print "\n|-- Actual Available BTC: ".$self->deci($self->{availableBtc})."\n";
    print "|-- Max Invest Per: " . $self->{investPercent} ."\n";
    my $randBuyPercent = (int(rand( $self->{investPercent})) + 1) * 0.01;
    print "|-- Random Max Trade Amount Is Enabled and Set To ".($randBuyPercent * 100 )."% of Available BTC (Minimum: 0.00062500) )\n";
    $availableBalance = ($randBuyPercent * $self->{availableBtc}); 
    print "|-- Random Max Trade Amount Becomes ".$self->deci($availableBalance)." BTC\n";
    if ( $availableBalance < 0.00062500  ) {
        print "|-- Random Max Trade Amount Was Too Small!!\n";
        if ( $self->{availableBtc} > 0.00062500 ) { 
            print "|-- Setting Trade Amount To 0.00062500\n";
            $availableBalance = $self->deci(0.00062500);
        } else {
            print "|-- Cannot Meet Minimum Trade Amount of 0.00062500\n";
            return 0;
        }
    }
    my $affordAmount = 0;    
    # use available BTC balance to determine how many of these we can afford to buy, if we bought
    if ( $coinPrice > 0 ) {
        $affordAmount = $self->deci(($availableBalance / $coinPrice));
    } else { $affordAmount = 0; return $affordAmount; }
    print "|-- How Much Can We Afford To Buy?\n";
    print "|-- I have ".$self->deci($availableBalance)." BTC To Spend, I can Afford to Buy ".$self->deci($affordAmount)." $coin @ ".$self->deci($coinPrice)." BTC per $coin For ".$self->deci(($affordAmount * $coinPrice))." BTC.\n";
    #print "|-- However Commission will be 0.25%\n";
    print "|-- 0.25% of ".$self->deci(($affordAmount * $coinPrice))." is ".$self->deci((($affordAmount * $coinPrice) * 0.0025))."\n";
    my $buyCommission = $self->deci(($affordAmount * $coinPrice) * 0.0025);    
    $affordAmount = $self->deci((($availableBalance - $buyCommission) / $coinPrice));
    print "|-- FINAL: I can Afford to Buy ".$self->deci($affordAmount)." $coin @ ".$self->deci($coinPrice)." BTC per $coin For ".$self->deci(($affordAmount * $coinPrice))." BTC.\n";
    if ( $self->deci(($affordAmount * $coinPrice)) > $self->deci(0.00062000) ) { 
        return $self->deci($affordAmount);
    } else {
        print "|-- Cannot Meet Minimum Trade Amount of 0.00062000 After Commission Adjustments\n";
        return 0;
    }    
}


##########
# Actions!
##########
sub placeBuyOrder {
    my ($self,$coin,$buyAmount,$bidPrice,$sellFor,$bCom,$sCom) = @_;
    print "\n|-- ".localtime()."\n";
    print "\n|-- placeBuyOrder \n";
    print "|--- Coin: $coin\n";
    print "|--- BidPrice: $bidPrice\n";
    print "|--- BuyAmount: $buyAmount\n";
    my $prepUrl = 'https://bittrex.com/api/v1.1/market/buylimit?apikey=' . $self->{bittrexApiKey} . '&market=BTC-'. $coin .'&quantity='.$self->deci($buyAmount).'&rate='.$self->deci($bidPrice).'&nonce='.time();
    my $sig = $self->getApiSig($prepUrl,time());
    my $ua = LWP::UserAgent->new;
    my $req = HTTP::Request->new( GET => $prepUrl );
    $req->header('apisign' => $sig );    
    my $res = $ua->request($req);
    
    if ( $res->{_rc} == 200 ) {
        #print "|--- Response Code $res->{_rc} $res->{_msg} --- \r\n";
        my $json = decode_json($res->decoded_content);
        #print Dumper($json);
        if ( length($json->{message}) > 0 ) { 
            print "|!! Bad Message Response: $json->{message}\n";
            if ( $json->{message} =~ /API/ || $json->{message} =~ /INVALID_SIGNATURE/ ) {
                    $self->logToFile("API ERROR OCCURRED at ".localtime()."\r\n");
                    $self->logToFile("Message: $json->{message} \r\n");
                    $self->logToFile("Sig Length: " . length($sig) . "\r\n");
                    $self->logToFile("Key Length: " . length($self->{bittrexApiKey}) . "\r\n");
                    print "|-- API ERROR Logged To File!\n";
                    #exec "nohup gimmeBitcoinzz.sh  >> ./reStarted.log 2>&1 &";
                    exec $^X, "gimmeBitcoinzz.sh";
                    $self->logToFile("API ERROR Causing RESTART_PROCESS at ".localtime()."\r\n GOODBYE CRUEL API!!\r\n");
                    exit(1);
                    #select(undef,undef,undef,2); # pause 1 seconds
            }
        } else {
            # we got it...
            # create the autoTrade for this buy
            print "|-- PURCHASE SUCCESSFUL [Creating AutoTrade]\n";
            $self->createAutoTrade($coin,$json->{result}->{uuid},'LIMIT_BUY',$bidPrice,$sellFor,$buyAmount,($bidPrice * $buyAmount),($sellFor * $buyAmount),$bCom,$sCom);
            $self->{availableBtc} -= ($bidPrice * $buyAmount);
            print "|-- End placeBuyOrder\n"; 
            select(undef,undef,undef,2); # pause 
        }
    } else {
        print "|-- Response Code $res->{_rc} $res->{_msg} --- \r\n";
        print "|-- End placeBuyOrder\n"; 
    }
}

sub placeSellOrder {
    my ($self,$coin,$sellAmount,$sellPrice,$boughtFor,$bCom,$sCom,$redo) = @_;
    if ( $redo != 123 ) { $redo = 0; }
    print "\n|-- ".localtime()."\n";
    print "\n|-- placeSellOrder \n";
    print "|--- Coin: $coin\n";
    print "|--- SellPrice: " . $self->deci($sellPrice)."\n";
    print "|--- SellAmount: ". $self->deci($sellAmount)."\n";
    my $prepUrl = 'https://bittrex.com/api/v1.1/market/selllimit?apikey=' . $self->{bittrexApiKey} . '&market=BTC-'. $coin .'&quantity='.$self->deci($sellAmount).'&rate='.$self->deci($sellPrice).'&nonce='.time();
    my $sig = $self->getApiSig($prepUrl,time());
    my $ua = LWP::UserAgent->new;
    my $req = HTTP::Request->new( GET => $prepUrl );
    $req->header('apisign' => $sig );    
    my $res = $ua->request($req);
    
    if ( $res->{_rc} == 200 ) {
        #print "|--- Response Code $res->{_rc} $res->{_msg} --- \r\n";
        my $json = decode_json($res->decoded_content);
        #print Dumper($json);
        if ( length($json->{message}) > 0 ) { 
            if ( $json->{message} eq 'INSUFFICIENT_FUNDS' && $redo != 123) {
                $self->logToFile("INSUF_FUNDS_Message: $json->{message} \r\n");
                $sellAmount -= 0.00000100;                
                while ( $self->placeSellOrder($coin,$sellAmount,$sellPrice,$boughtFor,$bCom,$sCom,123) eq 'fail') {                    
                    $sellAmount -= 0.00000100;       
                    $self->{retrySells} += 1;
                    if ( $self->{retrySells} > $self->{retrySellMax} ) { 
                        print "|-- Giving up On Place Sell Order!\n";
                        $self->{retrySells} = 0;
                        last;
                    }
                    select(undef,undef,undef,1); # pause 1 seconds
                }                
            } else {
                print "|!! Unknown Message Response: $json->{message}\n"; 
                if ( $json->{message} =~ /API/ || $json->{message} =~ /INVALID_SIGNATURE/ ) {
                    $self->logToFile("API ERROR OCCURRED at ".localtime()."\r\n");
                    $self->logToFile("Message: $json->{message} \r\n");
                    $self->logToFile("Sig Length: " . length($sig) . "\r\n");
                    $self->logToFile("Key Length: " . length($self->{bittrexApiKey}) . "\r\n");
                    print "|-- API ERROR Logged To File!\n";
                    #`sh gimmeBitcoinzz.sh  >> ./reStarted.log 2>&1 &`;
                    #exec "nohup gimmeBitcoinzz.sh  >> ./reStarted.log 2>&1 &";
                    exec $^X, "gimmeBitcoinzz.sh";
                    $self->logToFile("API ERROR Causing RESTART_PROCESS at ".localtime()."\r\n GOODBYE CRUEL API!!\r\n");
                    exit(1);
                    #select(undef,undef,undef,120); # pause 2 minutes
                }                                
                print "|-- End placeSellOrder\n"; 
                if ( $json->{message} eq 'INSUFFICIENT_FUNDS' ) { 
                    $self->logToFile("INSUF_FUNDS_Message: $json->{message} \r\n");
                    
                }
                if ( $redo == 123 ) { return 'fail'; }
            }
        } else {
            # we got it...
            # create the autoTrade for this sell
            print "|-- SELL ORDER SUCCESSFUL [Creating AutoTrade]\n";
            $self->createAutoTrade($coin,$json->{result}->{uuid},'LIMIT_SELL',$boughtFor,$sellPrice,$sellAmount,($boughtFor * $sellAmount),($sellPrice * $sellAmount),$bCom,$sCom);
            print "|-- End placeSellOrder\n"; 
            
            select(undef,undef,undef,2); # pause 1 second
            if ( $redo == 123 ) { return 'good'; }
        }
    } else {
        print "|-- Response Code $res->{_rc} $res->{_msg} --- \r\n";
        print "|-- End placeSellOrder\n"; 
    }
}

sub cancelOrder {
    my ($self,$uuid) = @_;
    print "\n|-- ".localtime()."\n";
    print "|-- cancelOrder \n";
    print "|--- Uuid: $uuid\n";
    my $prepUrl = "https://bittrex.com/api/v1.1/market/cancel?apikey=".$self->{bittrexApiKey}."&uuid=" . $uuid . "&nonce=".time();
    my $sig = $self->getApiSig($prepUrl,time());
    my $ua = LWP::UserAgent->new;
    my $req = HTTP::Request->new( GET => $prepUrl );
    print "|-- Sig Len: ". length($sig) . "\n";
    $req->header('apisign' => $sig );    
    my $res = $ua->request($req);
    
    if ( $res->{_rc} == 200 ) {
        #print "|--- Response Code $res->{_rc} $res->{_msg} --- \r\n";
        my $json = decode_json($res->decoded_content);
        #print Dumper($json);
        if ( length($json->{message}) > 0 ) { 
            print "|!! Bad Message Response: $json->{message}\n"; 
            if ( $json->{message} =~ /API/ || $json->{message} =~ /INVALID_SIGNATURE/ ) {
                $self->logToFile("API ERROR OCCURRED at ".localtime()."\r\n");
                $self->logToFile("Message: $json->{message} \r\n");
                $self->logToFile("Sig Length: " . length($sig) . "\r\n");
                $self->logToFile("Key Length: " . length($self->{bittrexApiKey}) . "\r\n");
                print "|-- API ERROR Logged To File!\n";
                #`sh gimmeBitcoinzz.sh  >> ./reStarted.log 2>&1 &`;
                #exec "nohup gimmeBitcoinzz.sh  >> ./reStarted.log 2>&1 &";
                exec $^X, "gimmeBitcoinzz.sh";
                $self->logToFile("API ERROR Causing RESTART_PROCESS at ".localtime()."\r\n GOODBYE CRUEL API!!\r\n");
                exit(1);
                #select(undef,undef,undef,2); # pause
            } elsif ( $json->{message} =~ /ORDER_NOT_OPEN/ ) { 
                print "|-- CANCEL ORDER FAILED [Removing AutoTrade To Prevent Dupe Attempts]\n";
                my $db = $self->getDb();
                my $remover = $db->do("DELETE FROM autoTrades WHERE uuid='".$uuid."'");
                $db->disconnect();
            }
            print "|-- End cancelOrder\n"; 
            select(undef,undef,undef,1); # pause
        } else {
            # Cancelled!
            # remove any autoTrade for this uuid
            print "|-- CANCEL ORDER SUCCESSFUL [Removing AutoTrade]\n";
            my $db = $self->getDb();
            my $remover = $db->do("DELETE FROM autoTrades WHERE uuid='".$uuid."'");
            $db->disconnect();
            print "|-- End cancelOrder\n"; 
            select(undef,undef,undef,2); # pause 5 seconds
        }
    } else {
        print "|-- Response Code $res->{_rc} $res->{_msg} --- \r\n";
        print "|-- End cancelOrder\n"; 
    }    
}

######################
# Auto Trade Functions
######################
sub getTotalPayout{
	my ($self)=@_;
	my $db = $self->getDb();
	my $sql = "SELECT total from payout order by total DESC";
	my $sth = $db->prepare($sql);
	$sth->execute();
	my $row  = $sth->fetchrow_hashref();
	#print $$row{total};
	$self{totalPayout} = $$row{total};
	print "Payout : ".$self{totalPayout}."\n";
	$sth->finish();
	$db->disconnect();
}
sub setPayout {
	my ($self, $payout) = @_;
	my $db = $self->getDb();
	$self{totalPayout} = $self->deci($self{totalPayout} + $payout);
	print "Total: ".$self{totalPayout}."\n";
	print "|--- Total Payout: ".$self{totalPayout}."\n";
	$db->do("insert into payout (payout, total) values ($payout, $self{totalPayout})");
	#$sth->finish();
	$db->disconnect();
}
sub createAutoTrade {
    my ($self,$coin,$uuid,$type,$perUnitBuyPrice,$perUnitSellPrice,$amount,$totalBuyPrice,$totalSellPrice,$buyCommission,$sellCommission) = @_;
    my $profitBefore = $self->deci($totalSellPrice - $totalBuyPrice);
    my $profitAfter = $self->deci(($totalSellPrice - $totalBuyPrice) - ( $buyCommission + $sellCommission ) );
    my $db = $self->getDb();
    my $insertz = $db->do("INSERT INTO autoTrades ( coin,uuid,type,perUnitBuyPrice,perUnitSellPrice,amount,totalBuyPrice,totalSellPrice,profitBeforeCommission,profitAfterCommission,buyCommission,sellCommission,remaining) ".
                          "VALUES ( '$coin','$uuid','$type',$perUnitBuyPrice,$perUnitSellPrice,$amount,$totalBuyPrice,$totalSellPrice,$profitBefore,$profitAfter,$buyCommission,$sellCommission,$amount)");
    $db->disconnect();
}

sub resolveThisAutoTrade {
    my ($self,$uuid) = @_;
    
}

sub autoResolveAutoTrades {
    my ($self) = @_;
    # Simply check ORDER HISTORY for the uuid, if its there, the trade is RESOLVED (sells are resolved and SOLD)
    print "\n|--- ".localtime()." \n";
    print "|--- Checking For Resolved Automatic Trades... \n";
    my $getCheck = "SELECT * FROM autoTrades WHERE resolved = 0";
    my $db = $self->getDb();
    my $sth = $db->prepare($getCheck);
    $sth->execute();    
    while ( my $row = $sth->fetchrow_hashref() ) {
        #print "|--- Checking Trade UUID: $row->{uuid} [$row->{type}] [Placed $row->{placed}]";
        my $sth2 = $db->prepare("SELECT COUNT(*) from orderHistory WHERE uuid=\'$row->{uuid}\'");
        $sth2->execute();
        my $foundIt = $sth2->fetchrow_hashref();
        if ( $foundIt->{'COUNT(*)'} > 0 ) {
            print " [RESOLVED]\n";
            print "|--- FOUND Trade UUID: $row->{uuid} \n";
            print "|--- Trade IS RESOLVED!\n";    
            # mark resolved
            if ( $row->{type} eq 'LIMIT_BUY' ) {
                if ( $self->deci($row->{remaining}) < 0.00000001 ) {
                    my $uth = $db->do("UPDATE autoTrades SET resolved=1 WHERE uuid=\'$row->{uuid}\'");
                    print "|--- This was a Purchase, Sell It NOW For AT LEAST: ".$self->deci($row->{perUnitSellPrice})."\n";                                        
                    #just sell it 
                    my $detail = $self->fetchOrderDetails($row->{uuid});
                    #print Dumper($detail);
                    $row->{amount} = $detail->{Quantity};
                    $row->{buyCommission} = $detail->{CommissionPaid};                    
                    $self->placeSellOrder($row->{coin},$self->deci($row->{amount}),$self->deci($row->{perUnitSellPrice}),$self->deci($row->{perUnitBuyPrice}),$self->deci($row->{buyCommission}),$self->deci($row->{sellCommission}) );
	            $self->{delayBuyCyclesRemaining} = 10; #roughly 1-90 minutes (OR MUCH LONGER DEPENDING ON delays For Cancels,buys,sells,retries,etc AND THATS FINE!) 
                } else { print "|--- PARTIAL $row->{type} Remaining: $self->deci($row->{remaining}) $row->{coin} $row->{uuid}\n"; }
            } elsif ( $row->{type} eq 'LIMIT_SELL' ) {    
                if ( $self->deci($row->{remaining}) < 0.00000001 ) {
                    $self->printSellArt();
                    print color('bold green');
                    print "|--- Yay! We Sold it!\n";
                    print "|--- Bought For: ".$self->deci($row->{totalBuyPrice})."\n";
                    print "|--- Sold For: ".$self->deci($row->{totalSellPrice})."\n";
                    print "|--- Commission: ".$self->deci(($row->{totalSellPrice} * 0.0025))."\n";                
                    print color('bold red');
                    print "|--- REMAINING: " . $self->deci($row->{remaining}) . " (SHOULD ALWAYS BE ZERO)\n";
                    print "|--- Profit After Commission: ".$self->deci((($row->{totalSellPrice} - ($row->{totalSellPrice} * 0.0025)) - ($row->{totalBuyPrice} - * 0.0025) ))."\n";
                    print color('reset');
		    print color('bold green');
		   	my $tmp = $self->deci((($row->{totalSellPrice} - ($row->{totalSellPrice} * 0.0025)) - ($row->{totalBuyPrice} - * 0.0025) ));
			my $reserved = $self->deci($tmp * $self{payoutPercentage});
			$self->setPayout($reserved);
		    print "|--- Reserving ".$self->deci($reserved)." BTC\n"; 
		    print "|--- Profit after reserved BTC: ".$self->deci($tmp-$reserved)."\n";
		    print color('reset');
		    if($self->{delayBuyCyclesRemaining} == 0){
	                    $self->{delayBuyCyclesRemaining} = 80; #roughly 1-90 minutes (OR MUCH LONGER DEPENDING ON delays For Cancels,buys,sells,retries,etc AND THATS FINE!)
		    }
                    # mark Sold
                    my $uth = $db->do("UPDATE autoTrades SET resolved=1 WHERE uuid=\'$row->{uuid}\'");

                    my $uth3 = $db->do("UPDATE autoTrades SET sold=1 WHERE uuid=\'$row->{uuid}\'");
                    my $uth4 = $db->do("UPDATE autoTrades SET closed=NOW() WHERE uuid=\'$row->{uuid}\'");
                }
            }
        } else {
            #print " [ACTIVE]\n";
        }
    }
    print "|-- end autoResolveAutoTrades\n";
    $sth->finish();
    $db->disconnect();
}

sub trimOldBuys {
    my ($self,$olderThan) = @_;
    print "\n|-- ".localtime()." \n";
    print "|-- Trimming Buys Older Than $olderThan Minutes\n";
    # Any buys older than $olderThan MINUTES that are NOT RESOLVED, should be cancelled (delete autoTrade and cancel order)
    my $db = $self->getDb();
    my $sth = $db->prepare("SELECT * FROM autoTrades where type='LIMIT_BUY' AND placed <= DATE_SUB( NOW() , INTERVAL $olderThan MINUTE ) AND resolved=0");
    $sth->execute();
    while ( my $row = $sth->fetchrow_hashref()) {
        my $cancelUuid = $row->{uuid};
        if ( $self->deci($row->{remaining}) == $self->deci($row->{amount}) ) {
            $self->cancelOrder($cancelUuid);
        } else {
            print "|-- Partial Or Filled Buy, Leaving it alone.\n";
            print "|-- Amount ". $self->deci($row->{amount}) . "\n";
            print "|-- Remaining ". $self->deci($row->{remaining}) . "\n";
        }
    }
    $db->disconnect();
    print "|-- End trimOldBuys($olderThan)\n";
}


sub dragDownSells {
    my ($self,$olderThan) = @_;
    # Any sells older than $olderThan MINUTES that are NOT SOLD, should be cancelled and REPRICED, then re-placeSellOrder and re-createAutoTrade
    print "\n|-- ".localtime()." \n";
    print "|-- Drag Down Sells Older Than $olderThan Minutes\n";   
    my $db = $self->getDb();
    my $sth = $db->prepare("SELECT * FROM autoTrades where type='LIMIT_SELL' AND placed <= DATE_SUB( NOW() , INTERVAL $olderThan MINUTE ) AND sold=0");
    $sth->execute();
    while ( my $row = $sth->fetchrow_hashref()) {
        # drag down rules
            my $boughtAt = $row->{perUnitBuyPrice};
            my $howMany = $row->{amount};
            my $totalBuy = $row->{amount} * $row->{perUnitBuyPrice};
            my $sellAt = $row->{perUnitSellPrice};
            my $totalSell = $row->{amount} * $row->{perUnitSellPrice};
            my $sellCommission = $totalSell * 0.0025;
            my $diff = $totalSell - $totalBuy;
            my $diffAfter = $diff - $sellCommission;
            my $profitPercent = (($diffAfter / $totalBuy) * 100);
            my $fivePercentOfProfit = ($diff * 0.05); #5% of profit BEFORE commission (thats important)
            my $afterDrag = $diff - $fivePercentOfProfit;
            my $newPerUnit = ($afterDrag + $totalBuy) / $howMany;
            my $newTotalSell = ($newPerUnit * $howMany);
            my $newProfit = ($newTotalSell - $totalBuy);
            my $newSellCommission = ($newTotalSell * 0.0025);
            my $newProfitAfter = (($newProfit - $newSellCommission) - $row->{buyCommission});
            
            #print "\n|--- Uuid: ".$row->{uuid}."\n";
            #print "|--- $row->{coin} - Bought For: ".$self->deci($boughtAt)." - Total Buy: ".$self->deci($totalBuy)."\n";
            #print "|--- Sell For: ".$self->deci($sellAt)." - Total Sell: ".$self->deci($totalSell)."\n";
            #print "|--- Difference: ".$self->deci($diff)."\n";
            #print "|--- Sell Commission: ".$self->deci($sellCommission)."\n";
            #print "|--- Difference After Commission: ".$self->deci($diffAfter)."\n";
            #print "|--- Profit Percent: ".$self->deci($profitPercent)."% Of Initial Invest\n";
            #print "|--- ***WARNING*** Reducing Profit of ".$self->deci($diff)." by FIVE Percent ***WARNING***\n";
            #print "|--- ***WARNING*** Reducing Profit of ".$self->deci($diff)." by FIVE Percent ***WARNING***\n";
            #print "|--- Five Percent Of Profit is: ".$self->deci($fivePercentOfProfit)."\n";
            #print "|--- ".$self->deci($diff)." Minus ".$self->deci($fivePercentOfProfit)." is ".$self->deci($afterDrag)."\n";
            ################################################################
            # New Values Here
            #################
            #print "|--- New Per Unit Price: ".$self->deci($newPerUnit)."\n";
            #print "|--- New Total Price: ".$self->deci($newTotalSell)."\n";
            #print "|--- New Sell Commission: ".$self->deci($newSellCommission)."\n";
            #print "|--- New Profit: ".$self->deci($newProfit)."\n";
            #print "|--- New Profit After Commission: ".$self->deci($newProfitAfter)."\n";
            if ( $newProfitAfter < 0.00000020  || $newTotalSell < 0.00050010 ) {
                #print "|--- New Profit SUCKS! Aborting Drag Down! Leave It Until It Sells!\n";
                $updateNowz = $db->do("update autoTrades set placed=NOW() WHERE uuid='".$row->{uuid}."'");
            } else {
                if ( $self->deci($row->{remaining}) == $self->deci($row->{amount}) ) {
                    # Cancel and Replace with lower Sell
                    print "\n|--- Uuid: ".$row->{uuid}."\n";
                    print "|--- $row->{coin} - Bought For: ".$self->deci($boughtAt)." - Total Buy: ".$self->deci($totalBuy)."\n";
                    print "|--- Sell For: ".$self->deci($sellAt)." - Total Sell: ".$self->deci($totalSell)."\n";
                    print "|--- New Profit After Commission: ".$self->deci($newProfitAfter)."\n";
                    print "|-- REPLACING THIS SELL ORDER WITH A LOWER PRICE THAT STILL PROFITS!\n";
                    #print "|-- (NOT REALLY NOT YET)\n";
                    $self->cancelOrder($row->{uuid});

                    # nice and easy (aka: omg i hope that worked)
                    print "|--- SELLING ".$self->deci($howMany)." OF $row->{coin} @ ".$self->deci($newPerUnit)." FOR  ".$self->deci($newTotalSell). "\n";
                    # $coin,$sellAmount,$sellPrice,$boughtFor,$bCom,$sCom
                    $self->placeSellOrder($row->{coin},$self->deci($howMany),$self->deci($newPerUnit),$self->deci($row->{perUnitBuyPrice}),$self->deci($row->{buyCommission}),$self->deci($newSellCommission) );
                } else {
                    print "|-- Partial Fill Sell, Leave It Alone!\n";
                    print "|-- Amount ". $self->deci($row->{amount}) . "\n";
                    print "|-- Remaining ". $self->deci($row->{remaining}) . "\n";
                    $updateNowz = $db->do("update autoTrades set placed=NOW() WHERE uuid='".$row->{uuid}."'");
                }
            }                
    }
    $db->disconnect();
    print "|-- End dragDownSells($olderThan)\n";
}


sub altDragDownSells {
    my ($self,$olderThan) = @_;
    # Any sells older than $olderThan MINUTES that are NOT SOLD, should be cancelled and REPRICED, then re-placeSellOrder and re-createAutoTrade
    print "\n|-- ".localtime()." \n";
    print "|-- Drag Down Sells Older Than $olderThan Minutes\n";   
    my $db = $self->getDb();
    my $sth = $db->prepare("SELECT * FROM autoTrades where type='LIMIT_SELL' AND placed <= DATE_SUB( NOW() , INTERVAL $olderThan MINUTE ) AND sold=0");
    $sth->execute();
    while ( my $row = $sth->fetchrow_hashref()) {
        # drag down rules
            my $abortDragLower = 0;
            my $boughtAt = $row->{perUnitBuyPrice};
            my $howMany = $row->{amount};
            my $totalBuy = $row->{amount} * $row->{perUnitBuyPrice};
            my $sellAt = $row->{perUnitSellPrice};
            my $totalSell = $row->{amount} * $row->{perUnitSellPrice};
            my $sellCommission = $totalSell * 0.0025;
            # dont use percent, use bid - 1 to determine drag
            my $newSellPrice = $self->deci($self->askCoinPrice($row->{coin},1) - 0.00000001 );
            my $newPerUnit = $newSellPrice;
            my $oldProfit = $self->deci($self->deci($totalSell) - $self->deci($totalBuy) - $row->{buyCommission});
            #print "|--- OLD PRICE: " . $self->deci($sellAt) . "\n";
            #print "|--- OLD PROFIT: " . $self->deci($oldProfit - $sellCommission) . "\n";
            #print "|--- NEW PRICE: " . $self->deci($newSellPrice) . "\n";
            if ( $self->deci($sellAt) == $self->deci($self->askCoinPrice($row->{coin},1)) ) {
                print "|-- Already Asking as Lowest Ask, aborting further dragDown\n";
                $abortDragLower = 1;
            }
            my $newTotalSell = $self->deci($newSellPrice * $howMany);
            my $newProfit = ($newTotalSell - $totalBuy);            
            my $newSellCommission = ($newTotalSell * 0.0025);
            my $newProfitAfter = (($newProfit - $newSellCommission) - $row->{buyCommission});
            print "|--- NEW PROFIT After Commission: " . $self->deci($newProfitAfter) . "\n";                        
            
            
            
            #print "\n|--- Uuid: ".$row->{uuid}."\n";
            #print "|--- $row->{coin} - Bought For: ".$self->deci($boughtAt)." - Total Buy: ".$self->deci($totalBuy)."\n";
            #print "|--- Sell For: ".$self->deci($sellAt)." - Total Sell: ".$self->deci($totalSell)."\n";
            #print "|--- Difference: ".$self->deci($diff)."\n";
            #print "|--- Sell Commission: ".$self->deci($sellCommission)."\n";
            #print "|--- Difference After Commission: ".$self->deci($diffAfter)."\n";
            #print "|--- Profit Percent: ".$self->deci($profitPercent)."% Of Initial Invest\n";
            #print "|--- ***WARNING*** Reducing Profit of ".$self->deci($diff)." by FIVE Percent ***WARNING***\n";
            #print "|--- ***WARNING*** Reducing Profit of ".$self->deci($diff)." by FIVE Percent ***WARNING***\n";
            #print "|--- Five Percent Of Profit is: ".$self->deci($fivePercentOfProfit)."\n";
            #print "|--- ".$self->deci($diff)." Minus ".$self->deci($fivePercentOfProfit)." is ".$self->deci($afterDrag)."\n";
            ################################################################
            # New Values Here
            #################
            #print "|--- New Per Unit Price: ".$self->deci($newPerUnit)."\n";
            #print "|--- New Total Price: ".$self->deci($newTotalSell)."\n";
            #print "|--- New Sell Commission: ".$self->deci($newSellCommission)."\n";
            #print "|--- New Profit: ".$self->deci($newProfit)."\n";
            #print "|--- New Profit After Commission: ".$self->deci($newProfitAfter)."\n";
            if ( $newProfitAfter < 0.00000050  || $newTotalSell < 0.00050010 || $abortDragLower == 1 ) {
                print "|--- New Profit SUCKS! Aborting Drag Down! Leave It Until It Sells!\n";
                $updateNowz = $db->do("update autoTrades set placed=NOW() WHERE uuid='".$row->{uuid}."'");
            } else {
                if ( $self->deci($row->{remaining}) == $self->deci($row->{amount}) ) {
                    # Cancel and Replace with lower Sell
                    print "\n|--- Uuid: ".$row->{uuid}."\n";
                    print "|--- $row->{coin} - Bought For: ".$self->deci($boughtAt)." - Total Buy: ".$self->deci($totalBuy)."\n";
                    print "|--- Sell For: ".$self->deci($sellAt)." - Total Sell: ".$self->deci($totalSell)."\n";
                    print "|--- New Profit After Commission: ".$self->deci($newProfitAfter)."\n";
                    print "|-- REPLACING THIS SELL ORDER WITH A LOWER PRICE THAT STILL PROFITS!\n";
                    #print "|-- (NOT REALLY NOT YET)\n";
                    $self->cancelOrder($row->{uuid});

                    # nice and easy (aka: omg i hope that worked)
                    print "|--- SELLING ".$self->deci($howMany)." OF $row->{coin} @ ".$self->deci($newPerUnit)." FOR  ".$self->deci($newTotalSell). "\n";
                    # $coin,$sellAmount,$sellPrice,$boughtFor,$bCom,$sCom
                    $self->placeSellOrder($row->{coin},$self->deci($howMany),$self->deci($newPerUnit),$self->deci($row->{perUnitBuyPrice}),$self->deci($row->{buyCommission}),$self->deci($newSellCommission) );
                } else {
                    print "|-- Partial Fill Sell, Leave It Alone!\n";
                    print "|-- Amount ". $self->deci($row->{amount}) . "\n";
                    print "|-- Remaining ". $self->deci($row->{remaining}) . "\n";
                    $updateNowz = $db->do("update autoTrades set placed=NOW() WHERE uuid='".$row->{uuid}."'");
                }
            }                
    }
    $db->disconnect();
    print "|-- End dragDownSells($olderThan)\n";
}

##########
# Fetchers
##########
sub fetchOrderDetails {
    my ($self,$uuid) = @_;
    my $prepUrl = "https://bittrex.com/api/v1.1/account/getorder?apikey=".$self->{bittrexApiKey}."&uuid=" . $uuid . "&nonce=".time();
    my $sig = $self->getApiSig($prepUrl,time());
    my $ua = LWP::UserAgent->new;
    my $req = HTTP::Request->new( GET => $prepUrl );
    $req->header('apisign' => $sig ); 
    my $res = $ua->request($req);
    
    if ( $res->{_rc} == 200 ) {
        #print "|--- Response Code $res->{_rc} $res->{_msg} --- \r\n";
        my $json = decode_json($res->decoded_content);
        if ( length($json->{message}) > 0 ) { 
            # weird fail?
            if ( $json->{message} =~ /API/ || $json->{message} =~ /INVALID_SIGNATURE/ ) {
                $self->logToFile("API ERROR OCCURRED at ".localtime()."\r\n");
                $self->logToFile("Message: $json->{message} \r\n");
                $self->logToFile("Sig Length: " . length($sig) . "\r\n");
                $self->logToFile("Key Length: " . length($self->{bittrexApiKey}) . "\r\n");
                print "|-- API ERROR Logged To File!\n";
                #`sh gimmeBitcoinzz.sh  >> ./reStarted.log 2>&1 &`;
                #exec "nohup gimmeBitcoinzz.sh  >> ./reStarted.log 2>&1 &";
                exec $^X, "gimmeBitcoinzz.sh";
                $self->logToFile("API ERROR Causing RESTART_PROCESS at ".localtime()."\r\n GOODBYE CRUEL API!!\r\n");
                exit(1);
                #select(undef,undef,undef,2); # pause
            }
            #print Dumper($json);
        } else {
            # success
            return $json->{result};
                        #		"AccountId" : null,
                        #		"OrderUuid" : "0cb4c4e4-bdc7-4e13-8c13-430e587d2cc1",
                        #		"Exchange" : "BTC-SHLD",
                        #		"Type" : "LIMIT_BUY",
                        #		"Quantity" : 1000.00000000,
                        #		"QuantityRemaining" : 1000.00000000,
                        #		"Limit" : 0.00000001,
                        #		"Reserved" : 0.00001000,
                        #		"ReserveRemaining" : 0.00001000,
                        #		"CommissionReserved" : 0.00000002,
                        #		"CommissionReserveRemaining" : 0.00000002,
                        #		"CommissionPaid" : 0.00000000,
                        #		"Price" : 0.00000000,
                        #		"PricePerUnit" : null,
                        #		"Opened" : "2014-07-13T07:45:46.27",
                        #		"Closed" : null,
                        #		"IsOpen" : true,
                        #		"Sentinel" : "6c454604-22e2-4fb4-892e-179eede20972",
                        #		"CancelInitiated" : false,
                        #		"ImmediateOrCancel" : false,
                        #		"IsConditional" : false,
                        #		"Condition" : "NONE",
                        #		"ConditionTarget" : null
                      
        }
    } else {
        
        print "|-- Response Code $res->{_rc} $res->{_msg} --- \r\n";
        print "|-- End fetchOrderDetails($uuid)\n"; 
    }    
}

sub priceCheck {
    my ($self) = @_;
    print "\n|-- Price Check\n";
    my $numToCheck = $self->countResults(" currencies WHERE (priceCheck=1 or balance > 0) and coin !='BTC' ");
    print "|-- $numToCheck Coins To Price Check!\n";
    if ( $numToCheck < 1 ) { return; }
    my $db = $self->getDb();
    my $cCnt = "SELECT * FROM currencies WHERE (priceCheck=1 or balance > 0) and coin !='BTC' ";
    my $sth = $db->prepare($cCnt);
    $sth->execute();
    while ( my $row = $sth->fetchrow_hashref() ) {
        print "|-- $row->{coin} - ";
        my $ticker = $self->fetchTicker($row->{coin});
        print "Bid: $ticker->{bid} - Ask: $ticker->{ask} - Last: $ticker->{last}\n";
        $self->insertAltCoinPriceHistory($row->{coin},$ticker);
    }
    print "|-- End priceCheck()\n";
    $sth->finish();
    $db->disconnect();
}

sub btcPriceCheck {
    my ($self) = @_;
    print "\n|-- BTC Price Check\n";
    my $btcPrice = $self->fetchBtcPrice();
    $self->{btcPrice} = $btcPrice;
}

sub fetchTradeableCoins {
    my ($self) = @_;
    my $coins = [];
    return $coins;
}

sub fetchOpenOrders {
    my ($self,$coin) = @_;
    my $prepUrl = 'https://bittrex.com/api/v1.1/market/getopenorders?apikey=' . $self->{bittrexApiKey} . '&market=BTC-'.$coin.'&nonce='. time();
    print "\n|-- Fetching Open Orders: $coin\n";
    my $sig = $self->getApiSig($prepUrl,time());
    my $ua = LWP::UserAgent->new;
    my $req = HTTP::Request->new( GET => $prepUrl );
    $req->header('apisign' => $sig );    
    my $res = $ua->request($req);
    if ( $res->{_rc} == 200 ) {
        #print "|--- Response Code $res->{_rc} $res->{_msg} --- \r\n";
        my $json = decode_json($res->decoded_content);
        if ( length($json->{message}) > 0 ) { 
            print "|!! Unknown Message Response: $json->{message}\n"; 
            if ( $json->{message} =~ /API/ || $json->{message} =~ /INVALID_SIGNATURE/ ) {
                $self->logToFile("API ERROR OCCURRED at ".localtime()."\r\n");
                $self->logToFile("Message: $json->{message} \r\n");
                $self->logToFile("Sig Length: " . length($sig) . "\r\n");
                $self->logToFile("Key Length: " . length($self->{bittrexApiKey}) . "\r\n");
                print "|-- API ERROR Logged To File!\n";
                #`sh gimmeBitcoinzz.sh  >> ./reStarted.log 2>&1 &`;
                exec $^X, "gimmeBitcoinzz.sh";
                #exec "nohup gimmeBitcoinzz.sh  >> ./reStarted.log 2>&1 &";
                $self->logToFile("API ERROR Causing RESTART_PROCESS at ".localtime()."\r\n GOODBYE CRUEL API!!\r\n");
                exit(1);
                #select(undef,undef,undef,2); # pause
            }
        } else {
            my $db = $self->getDb();
            my $uth = $db->do("DELETE FROM openOrders WHERE coin='".$coin."'");
            # all good
            my $result = $json->{result};
            print "|-- Got ". keys(@$result)." Results\n";
            foreach my $r(@$result) {
                #print Dumper($r);
                #print "|-- $r->{OrderType} - $r->{OrderUuid} - $r->{Quantity} - $r->{QuantityRemaining} $r->{Limit} $r->{Opened} $r->{Exchange}\n";
                #print "|-- '".$r->{OrderUuid}."','". $coin ."','". $r->{OrderType} ."',". $self->deci($r->{Limit}) .",". $self->deci($r->{Quantity}) .",". $self->deci($r->{QuantityRemaining}) .",". $self->deci($r->{Price}) .",". $self->deci($r->{CommissionPaid}) .",'". $r->{Opened} ."')\n";
                my $query = '';
                if ( $r->{OrderType} eq 'LIMIT_BUY' ) {
                    #is buy
                    $query ="INSERT INTO openOrders (uuid,coin,type,perUnitBuyPrice,amount,remaining,totalBuyPrice,buyCommission,placed) VALUES " .
                             "('".$r->{OrderUuid}."','". $coin ."','". $r->{OrderType} ."',". $self->deci($r->{Limit}) .",". $self->deci($r->{Quantity}) .",". $self->deci($r->{QuantityRemaining}) .",". $self->deci($r->{Price}) .",". $self->deci($r->{CommissionPaid}) .",'". $r->{Opened} ."')";
                } else {
                    #is sell
                    $query ="INSERT INTO openOrders (uuid,coin,type,perUnitSellPrice,amount,remaining,totalSellPrice,sellCommission,placed) VALUES " .
                             "('".$r->{OrderUuid}."','". $coin ."','". $r->{OrderType} ."',". $self->deci($r->{Limit}) .",". $self->deci($r->{Quantity}) .",". $self->deci($r->{QuantityRemaining}) .",". $self->deci($r->{Price}) .",". $self->deci($r->{CommissionPaid}) .",'". $r->{Opened} ."')";
                }
                # Run The Insert                
                my $uth = $db->do($query);
            }
            $db->disconnect();
        }
    } else {
        print "|--- Response Code $res->{_rc} $res->{_msg} --- \r\n";
        print "|-- End fetchOpenOrders($coin)\n";  
    }     
}

sub fetchOrderHistory {
    my ($self,$coin) = @_;
    my $prepUrl = 'https://bittrex.com/api/v1.1/account/getorderhistory?market=BTC-'.$coin.'&apikey=' . $self->{bittrexApiKey} . '&nonce=' . time();
    print "\n|-- Fetching Order History: $coin\n";
    my $sig = $self->getApiSig($prepUrl,time());
    my $ua = LWP::UserAgent->new;
    my $req = HTTP::Request->new( GET => $prepUrl );
    $req->header('apisign' => $sig );    
    my $res = $ua->request($req);
    if ( $res->{_rc} == 200 ) {
        #print "|--- Response Code $res->{_rc} $res->{_msg} --- \r\n";
        my $json = decode_json($res->decoded_content);
        if ( length($json->{message}) > 0 ) { 
            if ( $json->{message} =~ /API/ || $json->{message} =~ /INVALID_SIGNATURE/ ) {
                $self->logToFile("API ERROR OCCURRED at ".localtime()."\r\n");
                $self->logToFile("Message: $json->{message} \r\n");
                $self->logToFile("Sig Length: " . length($sig) . "\r\n");
                $self->logToFile("Key Length: " . length($self->{bittrexApiKey}) . "\r\n");
                print "|-- API ERROR Logged To File!\n";
                #`sh gimmeBitcoinzz.sh  >> ./reStarted.log 2>&1 &`;
                #exec "nohup gimmeBitcoinzz.sh  >> ./reStarted.log 2>&1 &";
                exec $^X, "gimmeBitcoinzz.sh";
                $self->logToFile("API ERROR Causing RESTART_PROCESS at ".localtime()."\r\n GOODBYE CRUEL API!!\r\n");
                exit(1);
                #select(undef,undef,undef,2); # pause
            }
            print "|!! Unknown Message Response: $json->{message}\n"; 
        } else {
            # all good
            my $result = $json->{result};
            #print Dumper($result);
            my $db = $self->getDb();
            my $purge = $db->do("DELETE from orderHistory where coin='".$coin."'");
            print "|-- Got ". keys(@$result)." Results\n";
            foreach my $o(@$result) {
                if ( $o->{OrderType} eq 'LIMIT_SELL') {
                    #is sell
                    my $ins = $db->do("INSERT INTO orderHistory (uuid,coin,type,perUnitSellPrice,totalSellPrice,closed,amount,remaining,sellCommission) ".
                    "VALUES ('".$o->{OrderUuid}."','$coin','LIMIT_SELL',".$self->deci($o->{PricePerUnit}).",".$self->deci($o->{Price}).",'". $o->{TimeStamp}."',".$self->deci($o->{Quantity}).",".$self->deci($o->{QuantityRemaining}).",".$self->deci($o->{Commission})  .")");
                } else {
                    #is buy
                    my $ins = $db->do("INSERT INTO orderHistory (uuid,coin,type,perUnitBuyPrice,totalBuyPrice,closed,amount,remaining,buyCommission) ".
                    "VALUES ('".$o->{OrderUuid}."','$coin','LIMIT_BUY',".$self->deci($o->{PricePerUnit}).",".$self->deci($o->{Price}).",'". $o->{TimeStamp}."',".$self->deci($o->{Quantity}).",".$self->deci($o->{QuantityRemaining}).",".$self->deci($o->{Commission})  .")");
                }
            }
            print "|-- End fetchOrderHistory($coin)\n";
            $db->disconnect();
        }
    } else {
        print "|--- Response Code $res->{_rc} $res->{_msg} --- \r\n";
        print "|-- End fetchOrderHistory($coin)\n";
    }
}

sub fetchBtcPrice {
    my ($self) = @_;
    print "\n|-- ".localtime()." \n";
    print "|-- Fetching Coinbase Bitcoin Price ---\r\n";
    $url = 'https://www.coinbase.com/';
    my $ua = LWP::UserAgent->new;
    my $req = HTTP::Request->new( GET => $url );
    my $res = $ua->request($req);
    my $content;
    #print Dumper($res);
    if ( $res->{_rc} == 200 ) {
        print "|--- Coinbase Price Response Code: $res->{_rc} $res->{_msg} ---\r\n";
        $content = $res->{_content};
        $content =~ /(1 BTC =\s.+)/;
        #print "Result $1\r\n";
        $content = $1;
        $content = substr($content, index($content,'$')+1);
	$content =~ s/','//g;
	$content =~ s/,//;
        print "|--- Bitcoin Price (Coinbase Exchange): $content\r\n";
        $self->insertBtcPriceHistory($content);
    } else {
        $content = 0.0;  
        print "|--- Coinbase Price Response Code: $res->{_rc} $res->{_msg} ---\r\n";
    }
    return $content;
}

sub fetchTicker {
    my ($self,$coin) = @_;
    my $nonce = time();
    my $prepUrl = 'https://bittrex.com/api/v1.1/public/getticker?market=btc-' . $coin; 
    my $ua = LWP::UserAgent->new;
    my $req = HTTP::Request->new( GET => $prepUrl );
    my $res = $ua->request($req);
    
    if ( $res->{_rc} == 200 ) {
        #print "|--- Response Code $res->{_rc} $res->{_msg} --- \r\n";
        my $json = decode_json($res->decoded_content);
        if ( length($json->{message}) > 0 ) { 
            print "|!! Unknown Message Response: $json->{message}\n"; 
        } else {
            # all good
            my $result = $json->{result};
            my $retVal = ();
            $retVal->{bid} = $self->deci($result->{Bid});
            $retVal->{ask} = $self->deci($result->{Ask});
            $retVal->{last} = $self->deci($result->{Last});
            return $retVal;
        }
    } else {
        print "|--- Response Code $res->{_rc} $res->{_msg} --- \r\n";
    }
}

sub fetchBalances {
    my ($self) = @_;
    print "\n|-- ".localtime()." \n";
    print "|-- Fetching All Balances\n";
    my $nonce = time();
    my $prepUrl = 'https://bittrex.com/api/v1.1/account/getbalances?apikey=' . $self->{bittrexApiKey} . '&nonce=' . $nonce;
    my $sig = $self->getApiSig($prepUrl,$nonce);
    my $ua = LWP::UserAgent->new;
    my $req = HTTP::Request->new( GET => $prepUrl );
    $req->header('apisign' => $sig );    
    my $res = $ua->request($req);
    if ( $res->{_rc} == 200 ) {
        print "|--- Response Code $res->{_rc} $res->{_msg} --- \r\n";
        my $json = decode_json($res->decoded_content);
        if ( length($json->{message}) > 0 ) { 
            print "|!! Unknown Message Response: $json->{message}\n"; 
            if ( $json->{message} =~ /API/ || $json->{message} =~ /INVALID_SIGNATURE/ ) {
                $self->logToFile("API ERROR OCCURRED at ".localtime()."\r\n");
                $self->logToFile("Message: $json->{message} \r\n");
                $self->logToFile("Sig Length: " . length($sig) . "\r\n");
                $self->logToFile("Key Length: " . length($self->{bittrexApiKey}) . "\r\n");
                print "|-- API ERROR Logged To File!\n";
                #`sh gimmeBitcoinzz.sh  >> ./reStarted.log 2>&1 &`;
                #exec "nohup gimmeBitcoinzz.sh  >> ./reStarted.log 2>&1 &";
                exec $^X, "gimmeBitcoinzz.sh";
                $self->logToFile("API ERROR Causing RESTART_PROCESS at ".localtime()."\r\n GOODBYE CRUEL API!!\r\n");
                exit(1);
                #select(undef,undef,undef,2); # pause
            }
        } else {
            # all good
            my $result = $json->{result};
            foreach my $a(@$result) {
                my $reserved = $self->deci($a->{Balance} - $a->{Available});
		if($a->{Currency} eq "BTC"){
	                print "|-- $a->{Currency} - Balance: ".$self->deci($a->{Balance})." - Available: ".$self->deci($a->{Available}-$self{totalPayout})." - Pending: ".$self->deci($a->{Pending})." - Reserved: ".$self->deci($reserved+$self{totalPayout})."\n";
        	        #$self->{availableBtc} = $a->{Available};
                	if(($a->{Available}-$self{totalPayout}) >= 0.00200000){
                        	$self->{availableBtc} = 0.00200000;
	                }else{
        	                $self->{availableBtc} = $a->{Available}-$self{totalPayout};
                	}

		}else{
                        print "|-- $a->{Currency} - Balance: ".$self->deci($a->{Balance})." - Available: ".$self->deci($a->{Available})." - Pending: ".$self->deci($a->{Pending})." - Reserved: $reserved\n";
		}
                $self->updateBalance($a->{Currency},$a->{Balance},$a->{Pending},$a->{Available});
            }
        }    
    } else {
        print "|--- Response Code $res->{_rc} $res->{_msg} --- \r\n";
    }
    print "|-- End fetchBalances()\n";
}

################
# Table Updaters
################
sub updateheldBtcHistory {
    my ($self) = @_;
#    mysql> CREATE TABLE heldBtcHistory (id int PRIMARY KEY AUTO_INCREMENT, date TIMESTAMP default NOW(),amount DECIMAL(16,8) default 0);
    

}

sub updatetotalBtcHistory {
    my ($self) = @_;
    print "\n|-- ".localtime()." \n";
    print "|-- Calculating Total Asset Estimates \n";

    # grab all coin balance total    
    # multiply each total by same coins btc value (bid);
    my @btcVals = ();
    my $findVals = "SELECT * FROM currencies WHERE balance > 0";
    #print " +++ $getCheck +++\n";
    my $db = $self->getDb();
    my $sth = $db->prepare($findVals);
    $sth->execute();
    while ( my $row = $sth->fetchrow_hashref() ) {
        my $allThisCoin = $row->{balance};
        my $thisCoinEstVal = 0;
        if ( $row->{coin} eq 'BTC' ) {
            $thisCoinEstVal = $allThisCoin;
        } else {
            $thisCoinEstVal = $allThisCoin * ($self->askCoinPrice($row->{coin},1) );
        }
        print "|-- Estimated Value of ".$self->deci($allThisCoin)." ".$row->{coin}." is ".$self->deci($thisCoinEstVal)." BTC (by ask price)\n";
        push @btcVals,$thisCoinEstVal;
    }
    $sth->finish();
    # sum of the btc values is the total Estimated BTC Value(btcAmount) (asset value approximate)    
    my $btcSum = 0;
    foreach my $val( @btcVals ) {
        $btcSum += $val;
    }
    print "|-- Estimated Value of All Assets is ".$self->deci($btcSum)." BTC\n";
    # add that to any existing Total Btc Balance (reserved is include in this 1:1) 
    # ^ABOVE^ IS NOT NEEDED!!! (if its over ZERO its included already)
    # multiply that totalBtc number by the current BTC price (coinbase) to get the usdAmount (also approximate,sale is not guaranteed in either case at any price)
    print "|-- Estimated USD Value of All Assets is \$".$self->trimToCents($self->deci(($btcSum * $self->{btcPrice})))." U\$D\n";
    #    mysql> CREATE TABLE totalBtcHistory (id int PRIMARY KEY AUTO_INCREMENT, date TIMESTAMP default NOW(),btcAmount DECIMAL(16,8) default 0,usdAmount DECIMAL(16,8) default 0);
    my $insertz = $db->do("INSERT INTO totalBtcHistory (btcAmount,usdAmount) VALUES (".$self->deci($btcSum).",".$self->trimToCents($self->deci(($btcSum * $self->{btcPrice}))).")");
    $db->disconnect();
}

sub trimToCents {
    my ($self,$value) = @_;
    my $result = substr($value, 0, index($value,'.')+3);
    return $result;
}

sub updateAutoTradeOrders {
    # check the order uuid (checkOrder) of each item in then autoTrades Table!
    # refill ALL relevant fields (remaining especially)
    
}

sub updateAutoTrade {    
    # update autoTrade with this uuid using info returned from a checkOrder
}

sub updateBalance {
    my ($self,$coin,$balance,$pending,$available) = @_;
    my $reserved = $balance - $available;
    # if row exists, update it, if not, insert it with defaults
    my $db = $self->getDb();
    my $query = "UPDATE currencies SET balance=$balance,pending=$pending,available=$available,reserve=$reserved,lastUpdated=CURRENT_TIMESTAMP WHERE coin='" . $coin ."'";
    my $rv  = $db->do($query);    
    if ( $rv eq '0E0' ) {
        print "|-- Balance Update Result => " . $rv . "\n";
        print '|-- No Such Coin: ' . $coin . " INSERTING with defaults.\n";        
        my $q2 = "INSERT INTO currencies ( coin,balance,pending,available,reserve ) VALUES ( '" 
                                         . $coin . "',$balance,$pending,$available,$reserved)"; 
        $rv  = $db->do($q2);                             
    } 
    $db->disconnect();
}

sub insertAltCoinPriceHistory {
    my ($self,$coin,$ticker) = @_;
    my $db = $self->getDb();
    #print "\n"."INSERT INTO altCoinPriceHistory (coin,bid,ask,price) VALUES ('". $coin ."',$ticker->{bid},$ticker->{ask},$ticker->{last}" . "\n";
    my $uth = $db->do("INSERT INTO altCoinPriceHistory (coin,bid,ask,price) VALUES ('". $coin ."',$ticker->{bid},$ticker->{ask},$ticker->{last})");
    $db->disconnect();
}

sub insertBtcPriceHistory {
    my ($self,$price) = @_;
    my $db = $self->getDb();
    #$price =~ s/,//;
    #my $uth = $db->do("INSERT INTO btcPriceHistory (price) VALUES ($price)");
    $db->disconnect();
}

sub populateCoinMetrics {
    my ($self,$range) = @_;
    if ( $range == null ) { $range = $self->{coinMetricsTimeRange}; }    
    print "\n|-- ".localtime(). "\n";    
    print "|-- populateCoinMetrics \n";
    print "|-- Scanning $range Hour(s) Of Collected Market Data ---\n";
    my $getCheck = "SELECT count(*) FROM currencies WHERE (priceCheck=1 or balance > 0) and coin != 'BTC' ";
    my $db = $self->getDb();
    my $sth = $db->prepare($getCheck);
    $sth->execute();
    my $cCnt = $sth->fetchrow_hashref();
    if ( $cCnt->{'count(*)'} > 0 ) { 
        print "|-- Found " . $cCnt->{'count(*)'} . " Coins To Price Check \n";
        $cCnt = "SELECT * FROM currencies WHERE (priceCheck=1 or balance > 0) and coin != 'BTC' ";
        $sth = $db->prepare($cCnt);
        $sth->execute();
        while ( my $row = $sth->fetchrow_hashref() ) {            
            my $coin = $row->{coin};
            $self->gatherCoinMetric($coin,$range);
        }
    } else {
        print "|-- No Tradable Coins In Database!\n";
    }

}

sub gatherCoinMetric {
    my ( $self,$coin, $range ) = @_;
    #print "|-- Gathering Metrics For " . $coin . " ($range hours)...\n";
    my $getCheck = "SELECT count(*) FROM altCoinPriceHistory WHERE coin=\'$coin\' and date >= DATE_SUB(NOW(), INTERVAL ". $range . " HOUR)";
    #print " +++ $getCheck +++\n";
    my $db = $self->getDb();
    my $sth = $db->prepare($getCheck);
    $sth->execute();
    my $cCnt = $sth->fetchrow_hashref();
    if ( $cCnt->{'count(*)'} > 0 ) { 
        #print "|--- Found " . $cCnt->{'count(*)'} . " $coin Prices...\n";
        my $sumPrices = $self->sumCoinMetric($coin,'price',$range);
        #print "|____ Sum Of Prices (last): ". deci($sumPrices)."\n";        
        my $avgPrice = ($sumPrices / $cCnt->{'count(*)'});
        my $low = $self->lowestCoinPrice($coin,$range);
        #print "|--- Average Price (last): ". deci(($sumPrices / $cCnt->{'count(*)'})) . "\n";
        my $high = $self->highestCoinPrice($coin,$range);
        my $gap = $high - $low;
        #print "|--- Gap: $gap\n";
        # get most current bid/ask/last
        my $getCur = "SELECT bid,ask,price FROM altCoinPriceHistory WHERE coin=\'$coin\' and date >= DATE_SUB(NOW(), INTERVAL ". $range . " HOUR) ORDER BY date DESC LIMIT 1";
        my $cth = $db->prepare($getCur);
        $cth->execute();
        my $currents = $cth->fetchrow_hashref();
        my $bid = $currents->{bid};
        my $ask = $currents->{ask};
        my $last = $currents->{price};
        my $volume = 0; #THIS NEEDS A FUNCTION TO FIND VOLUME PER COIN, boring, do it later
        $cth->finish();
        my $dv = $db->do("delete from coinMetrics where coin=\'$coin\'");
        #print "|-- Purged Existing $coin Metrics Row...\n";        
        my $query = "INSERT INTO coinMetrics (coin,averagePrice,lowestPrice,highestPrice,bid,ask,last,gap,volume,timeRange) " .
                            "VALUES (\'$coin\',$avgPrice,$low,$high,$bid,$ask,$last,$gap,$volume,$range)";                
        #print "\r\n" . $query . "\r\n\r\n";
        my $rv = $db->do($query);
        #print "|-- Inserted Data into Coin Metrics ---\r\n";
    } else {
        print "|-- Found No Prices for $coin\n";
    }
}

##################################
# Coin and Price Utility Functions
##################################
sub sumCoinMetric {
    my ($self,$coin,$metric,$range) = @_;
    my $getCheck = "SELECT $metric FROM altCoinPriceHistory WHERE coin=\'$coin\' and date >= DATE_SUB(NOW(), INTERVAL ". $range . " HOUR)";
    #print " +++ $getCheck +++\n";
    my $db = $self->getDb();
    my $sth = $db->prepare($getCheck);
    $sth->execute();
    my $sum = 0;
    while ( my $row = $sth->fetchrow_hashref() ) {
            $sum+=$row->{price};
            #print "|___ Sum Of Prices (Last Actual): " . deci($sum) . "\n";            
    }
    $sth->finish();
    $db->disconnect();
    return $sum;
}

sub lowestCoinPrice {
    my ($self,$coin,$range) = @_;
    my $getCheck = "SELECT * FROM altCoinPriceHistory WHERE coin=\'$coin\' and date >= DATE_SUB(NOW(), INTERVAL ". $range . " HOUR) ORDER BY price ASC LIMIT 1";
    #print " +++ $getCheck +++\n";
    my $db = $self->getDb();
    my $sth = $db->prepare($getCheck);
    $sth->execute();
    my $low = 0;
    while ( my $row = $sth->fetchrow_hashref() ) {
            #print "|--- Lowest Price (Last Actual): " . deci($row->{price}) . "\n";
            $low = $row->{price};
    }
    $sth->finish();
    $db->disconnect();
    return $low;
}

sub highestCoinPrice {
    my ($self,$coin,$range) = @_;
    my $getCheck = "SELECT * FROM altCoinPriceHistory WHERE coin=\'$coin\' and date >= DATE_SUB(NOW(), INTERVAL ". $range . " HOUR) ORDER BY price DESC LIMIT 1";
    #print " +++ $getCheck +++\n";
    my $db = $self->getDb();
    my $sth = $db->prepare($getCheck);
    $sth->execute();
    my $high = 0;
    while ( my $row = $sth->fetchrow_hashref() ) {
            #print "|--- Highest Price (Last Actual): " . deci($row->{price}) . "\n";
            $high = $row->{price};
    }
    $sth->finish();
    $db->disconnect();
    return $high;
}

sub bidCoinPrice {
    my ($self,$coin,$range) = @_;
    my $getCheck = "SELECT * FROM altCoinPriceHistory WHERE coin=\'$coin\' and date >= DATE_SUB(NOW(), INTERVAL ". $range . " HOUR) ORDER BY date DESC LIMIT 1";
    #print " +++ $getCheck +++\n";
    my $db = $self->getDb();
    my $sth = $db->prepare($getCheck);
    $sth->execute();
    my $bid = 0;
    while ( my $row = $sth->fetchrow_hashref() ) {
            #print "|____ Bid Price: " . deci($row->{bid}) . "\n";
            $bid = $row->{bid};
    }
    $sth->finish();
    $db->disconnect();
    return $bid;
}

sub askCoinPrice {
    my ($self,$coin,$range) = @_;
    my $getCheck = "SELECT * FROM altCoinPriceHistory WHERE coin=\'$coin\' and date >= DATE_SUB(NOW(), INTERVAL ". $range . " HOUR) ORDER BY date DESC LIMIT 1";
    #print " +++ $getCheck +++\n";
    my $db = $self->getDb();
    my $sth = $db->prepare($getCheck);
    $sth->execute();
    my $bid = 0;
    while ( my $row = $sth->fetchrow_hashref() ) {
            #print "|____ Ask Price: " . deci($row->{ask}) . "\n";
            $bid = $row->{ask};
    }
    $sth->finish();
    $db->disconnect();
    return $bid;
}

##########################
# Api Requests and Signing
##########################
sub getApiKey {
    my ($self) = @_;
    my $db = $self->getDb();
    my $sth = $db->prepare("SELECT * FROM accounts");
    $sth->execute();
    my $account = $sth->fetchrow_hashref();
    $sth->finish();
    $db->disconnect();
    return $account->{apiKey};
}

sub getApiSecret {
    my ($self) = @_;
    my $db = $self->getDb();
    my $sth = $db->prepare("SELECT * FROM accounts");
    $sth->execute();
    my $account = $sth->fetchrow_hashref();
    $sth->finish();
    $db->disconnect();
    return $account->{apiSecret};
}

sub getApiSig {
    my ($self,$uri,$nonce) = @_;
    my $secret = $self->getApiSecret();
    my $sig = `php ./sign.php \"$uri\" \"$secret\" \"$nonce\"`; #"
    return $sig;
}


#################
# Db Utility Subs
#################
sub createAccountsDbTable {
    my ($self) =@_;
    my $db = $self->getDb();
    my $sth = $db->do("CREATE TABLE accounts (id int PRIMARY KEY AUTO_INCREMENT
    ,exchange VARCHAR(24) NOT NULL, 
    apiKey VARCHAR(1024) NOT NULL, 
    apiSecret VARCHAR(1024) NOT NULL)") or die("|--- Couldn't DO statement: " . $db->errstr . "\n");
    print "|-- Accounts Table Created!\n";
    $db->disconnect();
}

sub createCurrenciesDbTable {
    my ($self) =@_;
    my $db = $self->getDb();
    my $sth = $db->do("CREATE TABLE currencies (id int PRIMARY KEY AUTO_INCREMENT,
    coin VARCHAR(16), balance DECIMAL(16,8) default 0,pending DECIMAL(16,8) default 0, reserve DECIMAL(16,8) default 0, available DECIMAL(16,8) default 0,
    lastUpdated TIMESTAMP default NOW(), tradeMe bool default 0, 
    tradeToZero bool default 0, priceCheck bool default 0, walletAddress VARCHAR(1024) )") or die("|--- Couldn't DO statement: " . $db->errstr . "\n");
    print "|-- Currencies Table Created!\n";
    $db->disconnect();
}

sub createOrderHistoryDbTable {
    my ($self) =@_;
    my $db = $self->getDb();
    my $sth = $db->do("CREATE TABLE orderHistory (id int PRIMARY KEY AUTO_INCREMENT, uuid VARCHAR(1024),
    coin VARCHAR(16), type VARCHAR(24), perUnitBuyPrice DECIMAL(16,8) default 0, perUnitSellPrice DECIMAL(16,8) default 0,
    amount DECIMAL(16,8) default 0, remaining DECIMAL(16,8) default 0, totalBuyPrice DECIMAL(16,8) default 0, totalSellPrice DECIMAL(16,8) default 0,
    profitBeforeCommission DECIMAL(16,8) default 0, profitAfterCommission DECIMAL(16,8) default 0, buyCommission DECIMAL(16,8) default 0,
    sellCommission DECIMAL(16,8) default 0, closed TIMESTAMP default NOW(), placed TIMESTAMP )") or die("|--- Couldn't DO statement: " . $db->errstr . "\n");
    print "|-- Order History Table Created!\n";
    $db->disconnect();
}

sub createAutoTradesDbTable {
    my ($self) =@_;
    my $db = $self->getDb();
    my $sth = $db->do("CREATE TABLE autoTrades (id int PRIMARY KEY AUTO_INCREMENT, uuid VARCHAR(1024),
    coin VARCHAR(16), type VARCHAR(24), perUnitBuyPrice DECIMAL(16,8) default 0, perUnitSellPrice DECIMAL(16,8) default 0,
    amount DECIMAL(16,8) default 0, remaining DECIMAL(16,8) default 0, totalBuyPrice DECIMAL(16,8) default 0, totalSellPrice DECIMAL(16,8) default 0,
    profitBeforeCommission DECIMAL(16,8) default 0, profitAfterCommission DECIMAL(16,8) default 0, buyCommission DECIMAL(16,8) default 0,
    sellCommission DECIMAL(16,8) default 0,  placed TIMESTAMP default NOW(),closed TIMESTAMP, resolved bool default 0, 
    sold bool default 0)") or die("|--- Couldn't DO statement: " . $db->errstr . "\n");
    print "|-- Auto Trades Table Created!\n";
    $db->disconnect();
}

sub createOpenOrdersDbTable {
    my ($self) =@_;
    my $db = $self->getDb();
    my $sth = $db->do("CREATE TABLE openOrders (id int PRIMARY KEY AUTO_INCREMENT, uuid VARCHAR(1024),
    coin VARCHAR(16), type VARCHAR(24), perUnitBuyPrice DECIMAL(16,8) default 0, perUnitSellPrice DECIMAL(16,8) default 0,
    amount DECIMAL(16,8) default 0, remaining DECIMAL(16,8) default 0, totalBuyPrice DECIMAL(16,8) default 0, totalSellPrice DECIMAL(16,8) default 0,
    profitBeforeCommission DECIMAL(16,8) default 0, profitAfterCommission DECIMAL(16,8) default 0, buyCommission DECIMAL(16,8) default 0,
    sellCommission DECIMAL(16,8) default 0, closed TIMESTAMP default NOW(), placed TIMESTAMP, resolved bool default 0, 
    sold bool default 0)") or die("|--- Couldn't DO statement: " . $db->errstr . "\n");
    print "|-- Open Orders Table Created!\n";
    $db->disconnect();
}

sub createCoinMetricsDbTable {
    my ($self) =@_;
    my $db = $self->getDb();
    my $sth = $db->do("CREATE TABLE coinMetrics (id int PRIMARY KEY AUTO_INCREMENT,
    coin VARCHAR(16), lowestPrice DECIMAL(16,8) default 0, highestPrice DECIMAL(16,8) default 0,
    averagePrice DECIMAL(16,8) default 0,bid DECIMAL(16,8) default 0, ask DECIMAL(16,8) default 0, last DECIMAL(16,8) default 0,
    gap DECIMAL(16,8) default 0, volume DECIMAL(16,8) default 0,timeRange int default 0)") or die("|--- Couldn't DO statement: " . $db->errstr . "\n");
    print "|-- Coin Metrics Table Created!\n";
    $db->disconnect();
}

sub createBtcPriceHistoryDbTable {
    my ($self) =@_;
    my $db = $self->getDb();
    my $sth = $db->do("CREATE TABLE btcPriceHistory (id int PRIMARY KEY AUTO_INCREMENT,
    date TIMESTAMP default NOW(),price DECIMAL(16,8) default 0)") or die("|--- Couldn't DO statement: " . $db->errstr . "\n");
    print "|-- BTC Price History Table Created!\n";
    $db->disconnect();
}

    #    mysql> CREATE TABLE totalBtcHistory (id int PRIMARY KEY AUTO_INCREMENT, date TIMESTAMP default NOW(),btcAmount DECIMAL(16,8) default 0,usdAmount DECIMAL(16,8) default 0);
sub createTotalBtcHistoryDbTable {
    my ($self) =@_;
    my $db = $self->getDb();
    my $sth = $db->do("CREATE TABLE totalBtcHistory (id int PRIMARY KEY AUTO_INCREMENT,
    date TIMESTAMP default NOW(),btcAmount DECIMAL(16,8) default 0,usdAmount DECIMAL(16,8) default 0)") or die("|--- Couldn't DO statement: " . $db->errstr . "\n");
    print "|-- Total BTC History Table Created!\n";
    $db->disconnect();
}


sub createAltCoinPriceHistoryDbTable {
    my ($self) =@_;
    my $db = $self->getDb();
    my $sth = $db->do("CREATE TABLE altCoinPriceHistory (id int PRIMARY KEY AUTO_INCREMENT,
    date TIMESTAMP default NOW(),price DECIMAL(16,8) default 0, coin VARCHAR(24), bid DECIMAL(16,8) default 0,ask DECIMAL(16,8) default 0)") or die("|--- Couldn't DO statement: " . $db->errstr . "\n");
    print "|-- Alt Coin Price History Table Created!\n";
    $db->disconnect();
}

sub doesTableExist {
    my ($self,$checkTable) = @_;
    my $db = $self->getDb();
    my $sth = $db->prepare("SELECT count(*) FROM information_schema.TABLES WHERE (TABLE_SCHEMA = \'$self->{dbName}\') AND (TABLE_NAME = \'$checkTable\')");
    $sth->execute();
    $row = $sth->fetchrow_hashref();
    if ( $row->{'count(*)'} > 0 ) {
        $sth->finish();
        $db->disconnect();
        return 1;
    }
    $sth->finish();
    $db->disconnect();
    return 0;
}

sub getDb {
    my ($self) = @_;
    my $dbi = DBI->connect("DBI:mysql:database=".$self->{dbName}.";host=" . $self->{dbHost},$self->{dbUser},$self->{dbPass});
    return $dbi;
}

sub countResults {
    my ($self,$query) = @_;
    $query = "SELECT COUNT(*) FROM " . $query;
    my $db = $self->getDb();
    my $sth = $db->prepare($query);
    $sth->execute();
    my $res = $sth->fetchrow_hashref();
    return $res->{'COUNT(*)'};
}

sub printSellArt {
    my ($self) = @_;
    print color('bold yellow');
    print "\n
77777 77          7777I?I?=,.,::=+++?=7777777777777777777777
77777777777777777I??,,:::==:~~~::~:,,+.==I777777777777777777
77777777777777I+:,~:~=?,+:~=~+~:,~,==~~:.===?777777777777777
777777777777==.~=~~.,~=.,,~~+,~=:~,,~~,,:~:,:=77777777777777
7777777777~=~:?~:~:~?,~:,~7+::=I?:,:~=.~:~+~,::~~77777777777
77777777?~::~~:~.~::~.:~~~~~~~~~~~~~,I,::=,=:~~,.~7777777777
7777777~,,+:~~~~::,:~~~~:~:~~~~~~~~~~~~:I:::~~::,:~777777777
777777~,,=~~.::?:~~~~~=:~~~:~~:===+~~~~~~:,:::~~~:,~?7777777
77777:::~:~,::,~~~==~~=:===~~~:===?~=~~=~~~~+:~:,:~,~+777777
7777~.:~~~~~I~~====+~==~+++~~=~+==?==+~====~~,:~~~~::~+77777
777~.:~,?==?++?+=?I??I?I?+?I???+++?I========~~:,~~:=,,=7 777
77I,~+~~~+=?III?+IIIIIII?III?I?????++?+:====+=~~:====~++7777
77?:++?+I?II777II77I7IIIIIIIIIIIII?????+~+=+++=+,=+=++=,7777
7I,?I?I+?I777777777I?777777~III?+?III????+???+??+I=?I,+I7777
77:I77+?+77777777777?777777~I77II,7IIIIII?IIIIIII?+7+II?+~77
77~I=III?7777777777I?777777:I777II7777I7~IIIIIII7II?++I?I777
?+I7?+++IIIIIIIIIIII+I77777:????7777777:II777III77.I=7=?,I77
7,IIIII=???~?~=?+?+++IIIIII7I777777777?I77777I+~I7+I+I??=I77
7,+I?:=:=~+~:==,:+:~=+?+??IIIIIIII77777+II777IIIII++I?I~:?77
I,~+~:,,~~:~,::,~.~:~~====+,==+=~IIIIII7I+IIIII???~+++==:+77
??~~~:+,::::::::::::::~~~~~,~~===~+????II?=??=?=?=?~=I,~~=77
7?,,..=,::::::,,,,,,:::::::,,:::=:.=====++====~~=~,~~,~,.=77
7=:,,,,,:,,,,,,,,,,,:,,,,,,,,:,::,:~~~~~~~,:~~~~:,,:,:,,=777
7+=,.:.:..,,,,,,,,..:,,,,,,..,,,.,::::::::,:::::,..,.:..: 77
77:,.:,.,.,,,,,,.,,,,,,,,,,,,,,,,,,,,,:,:.:,,,,,I,.,,,.+~777
77~~,,,,,..,,,,,.,,,,,,,,,,,,,,,,,,,,,,.,,,,,,,,,,.,,,.:7777
777:~,,,,:..,,,,,...,.,.:::....,,:~.,,,,,,,:,,~,,,,~..:77777
7777::,:,.:..,:::::::::,:::,::,:::~,::::::::,I,::::,=:777777
77777:.,~,:~~:7~~~~~~~~:~=~:~~:~~~=~~~~~~~::,:~~~~:.:,777777
777777=+:~=====~?==++++~+++:==~++++=+==+=~.==~===~.=77777777
7777777=+,=+=~+===,:==================~I~==:++==:~+777777777
777777777=~:~=+:~~=~~.?~~======~~~~~:~~==:+:~=~,=~7777777777
7777777777.=.:~=::.,~====~~~::~~~====~:,~~~~~~?=777777777777
777777777  7I+=:~==:~,~.+::=~==:~=::~+~~==::+?77777777777777
7777777777 77 7==~,::~~~::=:~=~~:::~~::,,+~~7777777777777777
7777777777 7 7  77::::.,,,,,,,,,,.=~.?::?7777777777777777777
7777777777777777777777=:,,,,,,,,,,~=777777777777777777777777
777777777        777777777 777777777777777777777777777777777\n";       
    print color('reset');
}


##########################
# Number Utitity Functions
##########################
sub nullVar {
    my ($self,$var) = @_;
    if ( !defined($var) || $var eq '' ) {
        return 1;
    }
}

sub deci {
    my ($self,$deciNum) = @_;
    return sprintf("%.8f",$deciNum);
}

sub logToFile {
   my ($self,$msg) = @_;
   my $time = localtime();
   open(my $fh,'>>',"faults.log");
   print $fh "|-- " . $time . " - " . $msg . "\n";
   close $fh;
   print "[LOG] " . $time . " - " . $msg . "\n";
}

1; # Same thing we do everynight, Pinky.
