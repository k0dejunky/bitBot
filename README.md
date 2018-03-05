# geekerV2
Geeker By GeekProjexDotCom</br>

CHANGE ALL FLOAT columns in the database to DECIMAL and use 16,8 for the size. This fixes rounding issues with the code.

# To donate</br>
1Apzahst2nUq226CyQJUHcHQKvy9nWoPvB </br>
(FEEDS DIRECTLY TO BOT)</br></br>

# What Is GeekerV2?
A cleaned up version of the Crypto Trading Automatron Currently Running GeekProjex.com</br>

# Better Instructions:
- Install a L.inux A.pache M.ySQL P.HP box (I like Linode.com shells for this) </br>
- Install PERL </br>
- Clone the git repo </br>
- Create a Mysql database it must be called 'geekerV2'</br>
- 'CREATE DATABASE geekerV2'</br>
- Make a user for mysql called geeker and choose a password for him. MUST be user called 'geeker'</br>
- CREATE USER 'geeker'@'localhost' IDENTIFIED BY 'yourpassword';</br>
- GRANT ALL PRIVILEGES ON  geekerV2.* TO 'geeker'@'localhost';</br>
- Thats all, remember that password.</br>
- Dont put any of this in the apache web folders, this part stays offweb, even the php file (the perl file runs it)</br>
- RUN IT FROM the folder it is inside (it needs to be in there with sign.php)</br>
- Run the bot ONCE. It will create accounts table in database and quit.</br>
- "perl geekerV2.pl yourDatabasePasswordForGeeker"</br>
- Use CPAN to fetch anything the bot fails to launch for (perl packages)</br>
- Go get a bittrex account with API key and API secret.</br>
- Put some bitcoin in it (I started mine with about 0.082 BTC (roughly $30-$40 USD)</br>
- INSERT into the accounts table a single row, with apiKey and apiSecret</br>
- On the first run the bot will put the coins you've traded in the past from your balance list on bittrex into the currency table</br>
- Using a database editor set tradeMe to 1 and priceCheck to 1 in the currency table for the ones you want to trade (if you want the bot to do anything)</br>
- Beware that USDT cannot be traded by this bot at this time, due to the way the pair has to look, so do not mark it for trade me or price check</br>
- Now, run the bot again and leave it alone (I use a detached screen session and an output redirect for logging)</br>
- Keep track of your BTC balance on Bittrex and it may  increase over time (once all sells complete)</br>
- Sometimes theres a selloff in the alt coin when the bot has a sell order on a alt coin. if you don't wish to wait, for it to come back up (possibly days, if ever) you will have to manually sell it on bittrex and take the loss.

# How to start the bot
Pass the Database Password for Database 'geekerV2' to ./geekerV2.pl</br>
Example: ./geekerV2.pl dbPassword

# Database
Database Name: geekerV2 (on localhost)</br>
Type: MySql

# Hows that work?
It starts with BITCOIN, sells it for ALT coins like DASH and LTC when their prices (in bitcoins) are LOW.</br>
It determines the LOW by the lowest price of 4 hours of monitoring the prices (note: works best after 4 hours of running)</br>
When it places buy orders at the LOWest price of the timeRange, it also finds the HIGHest price of same timeRange.</br>
It notes this, and IF that BUY is filled, it will IMMEDIATELY place the same amount bought for LOW amount BTC up for sale</br> for HIGH amount BTC. (ie: Buying LTC @ 0.00063000 BTC and selling it for 0.00064000 BTC)</br>
It will only place the BUY order in the first place, IF the sale of same at high will CLEAR THE COMMISSION charged for</br> the transaction by the exchange (bittrex charges 0.0025% on all).</br>

Once it BUYs it places for sale on HIGHest price of the timeRange it bought in.</br>
But what if it goes out of range? what if thats TOO high or a fluke or even MISdirection from others?</br>
Good question!
Thats why there is a DRAGdown Sell function, after 15 minutes, any sell not sold, will have its PROFIT lowered by 5%.</br>
It figures out the current PROFIT then calcs 5% of that, subtracts it, then funkymathTown to get the new UNIT price, </br>cancel the original sell order, and places a NEW sell order at the new price. The trick is, it WONT do this if </br>the NEW PROFIT is too low! So in essence, it buys as low as possible, TRIES to sell it super high, then gradually reduces</br> it until it pops. Very rarely does anything get stuck high anymore(it was an issue in the beginning of development,</br> this is the solution)

What about the buys? What if they never pop?</br>
Good Question!</br>
Thats why trimOldBuys(15) exists, just like dragdown but way simpler.</br>
For a buy that doesnt sell in the 15 minutes, it gets CANCELLED (unless its partially filled, then it stays)</br>
Its cancelled and forgotten if it doesnt get a bite.</br>
This works because in 10 seconds, it will see it has enough bitcoin (freed by the cancel) to make a buy and</br> it will, replacing the previous investment with a more time accurate offer.</br></br>

This isnt everything, some of it might not even be correct.
So far the experiment was profitible if guided.

# Database Tables
- accounts</br>
 exchange (which exchange are we using)</br>
 apiKey (the api key)</br>
 apiSecret (the api secret)</br>
 
- currencies</br>
 coin (The Coin)</br>
 balance (The Fun Part, sometimes...)</br>
 pending</br>
 reserve</br>
 available</br>
 lastUpdated </br>
 tradeMe (Boolean, Should we BUY this coin, then sell what we buy)</br>
 tradeToZero (Boolean, Should we SELL IT ALL, even if we didnt buy it first (harvestAllCoins) )</br>
 priceCheck (should we store price History for this Coin?)</br>

- orderHistory</br>
 uuid</br>
 type (LIMIT_BUY or LIMIT_SELL)</br>
 coin</br>
 perUnitBuyPrice</br>
 perUnitSellPrice</br>
 amount</br>
 remaining</br>
 totalBuyPrice</br>
 totalSellPrice</br>
 profitBeforeCommission</br>
 profitAfterCommission</br>
 buyCommission</br>
 sellCommission</br>
 placed (timestamp)</br>
 closed (timestamp)</br>

- autoTrades</br>
 uuid</br>
 type (LIMIT_BUY or LIMIT_SELL)</br>
 coin</br>
 perUnitBuyPrice</br>
 perUnitSellPrice</br>
 amount</br>
 remaining</br>
 totalBuyPrice</br>
 totalSellPrice</br>
 profitBeforeCommission</br>
 profitAfterCommission</br>
 buyCommission</br>
 sellCommission</br>
 placed (timestamp)</br>
 closed (timestamp)</br>
 resolved (boolean)</br>
 sold (boolean)</br>

- openOrders</br>
 uuid</br>
 type (LIMIT_BUY or LIMIT_SELL)</br>
 coin</br>
 perUnitBuyPrice</br>
 perUnitSellPrice</br>
 amount</br>
 remaining</br>
 totalBuyPrice</br>
 totalSellPrice</br>
 profitBeforeCommission</br>
 profitAfterCommission</br>
 buyCommission</br>
 sellCommission</br>
 placed (timestamp)</br>
 closed (timestamp)</br>
 resolved (boolean)</br>
 sold (boolean)</br>

- coinMetrics</br>
 coin</br>
 lowestPrice</br>
 highestPrice</br>
 averagePrice</br>
 bid</br>
 ask</br>
 last</br>
 gap</br>
 volume</br>
 range</br>

- btcPriceHistory</br>
 date
 price

- altCoinPriceHistory</br>
 date
 price
 bid
 ask
 coin

# Important Functions
The ones in the code, those are the important ones. Need those.
