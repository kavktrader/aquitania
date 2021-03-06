########################################################################################################################
# |||||||||||||||||||||||||||||||||||||||||||||||||| AQUITANIA ||||||||||||||||||||||||||||||||||||||||||||||||||||||| #
# |||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||| #
# |||| To be a thinker means to go by the factual evidence of a case, not by the judgment of others |||||||||||||||||| #
# |||| As there is no group stomach to digest collectively, there is no group mind to think collectively. |||||||||||| #
# |||| Each man must accept responsibility for his own life, each must be sovereign by his own judgment. ||||||||||||| #
# |||| If a man believes a claim to be true, then he must hold to this belief even though society opposes him. ||||||| #
# |||| Not only know what you want, but be willing to break all established conventions to accomplish it. |||||||||||| #
# |||| The merit of a design is the only credential that you require. |||||||||||||||||||||||||||||||||||||||||||||||| #
# |||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||| #
########################################################################################################################

"""
.. moduleauthor:: H Roark
"""
import bisect
import pandas as pd
import numpy as np
import os
from aquitania.data_processing.analytics_loader import build_liquidation_dfs
from cpython.datetime cimport datetime

cpdef build_exits(broker_instance, str asset, signal, int max_candles, bint is_dentro=False, bint is_virada=False):
    """
    Calculates exit DateTime for a list of Exit Points. It will be used in later module that evaluates winning or
    losing positions.

    :param broker_instance: (DataSource) Input broker instance
    :param asset: (str) Input asset
    :param signal: (AbstractSignal) Input signal
    :param max_candles: (int) Number of max G01 candles to look in the future to liquidate trade
    :param is_dentro: (bool) True if when positioned, don't look for new positions in the same side
    :param is_virada: (bool) True if when positioned, if there is a trade in the same side, you switch positions
    """

    # Initializes variables
    entry = signal.entry
    exit_points = {signal.stop, signal.profit}
    exits = None
    import time
    time_a = time.time()

    df, candles_df = build_dfs(broker_instance, asset, exit_points, entry)
    print('build_dfs: ', time.time() - time_a)

    time_b = time.time()
    exits = process_exit_points(df, exit_points, candles_df, max_candles, is_virada)
    print('process exit points: ', time.time() - time_b)

    # Sets filename
    filename = 'data/liquidation/' + asset + '_' + entry

    # Save liquidation to disk
    time_c = time.time()
    save_liquidation_to_disk(filename, exits)
    print('save liquidation to disk: ', time.time() - time_c)

    time_d = time.time()
    consolidate_exits(asset, entry, exits, is_dentro)
    print('consolidate exits: ', time.time() - time_d)

cdef build_dfs(broker_instance, asset, exit_points, entry):
    # Load DataFrames
    df = build_liquidation_dfs(broker_instance, asset, exit_points, entry)
    candles_df = broker_instance.load_data(asset)

    # Create Entry Point column
    candles_df['entry_point'] = candles_df['open'].shift(-1)

    # Build entry points and close values into exit DataFrame
    df = build_entry_points(df, candles_df)

    # Checks if df is empty and raise Warning if so.
    if df.shape[0] == 0:
        ValueError('There was a problem with the signal in your strategy, it didn\'t generate any ok=True.')

    # Clean Candles DF
    candles_df = candles_df[['open', 'high', 'low']]

    return df.sort_index(), candles_df

cdef process_exit_points(df, exit_points, candles_df, max_candles, is_virada):
    cdef object exits = None

    # Create exits for all exit points
    for exit_point in exit_points:
        # Run multiprocessing routine
        temp_exit = manage_exit_creation(df[['close', 'entry_point', exit_point]], exit_point, candles_df, max_candles)

        # Routine for df_alta
        temp_exit.columns = [exit_point + '_dt', exit_point + '_saldo']

        # Concat exits
        if exits is None:
            exits = temp_exit
        else:
            exits = pd.concat([exits, temp_exit], axis=1)
        del temp_exit

    # Routine if for every trade an opposite trade is automatically an entry
    if is_virada:
        virada_df = virada(df)
        exits = pd.concat([exits, virada_df], axis=1)

    # Quick fix to generate entry points for AI
    else:
        temp_df = df[['entry_point']]
        temp_df.columns = ['entry']
        exits = pd.concat([exits, temp_df], axis=1)

    return exits

cdef build_entry_points(df, candles_df):
    """
    The new feeder routine that was created to deal with the issue that there were outputted candles that were not
    in the right possible timing, which helped remove the .update_method() from indicator logic, need to have a fix
    because we will have output at TimeStamps that have never existing in 1 Minute candles.

    For this reason some kind of routine was needed to fetch those trades that were created in minutes that are not
    part of the original Database.

    :param df: (pandas DataFrame) Containing exit points.

    :return: DataFrame with exit points along with close and entry_point values
    :rtype: pandas DataFrame
    """

    # Generates inner join DataFrame
    df_inner = pd.concat([candles_df[['close', 'entry_point']], df], join='inner', axis=1)

    # Finds exit points for elements outside the inner join DataFrame
    for element in df.index.difference(df_inner.index):
        # Selects 1 month prior to the DataFrame, which is the highest period we use
        w = candles_df.loc[element - pd.offsets.Day(31):element + pd.offsets.Minute(1)].iloc[-1][
            ['close', 'entry_point']]

        # Changes index to be able to concat correctly
        w.name = element

        # Creates line to be added
        x = pd.concat([df.loc[element], w])

        # Add line to DataFrame
        df_inner.loc[element] = x

    # Returns ordered DataFrame
    return df_inner.sort_index()

cdef manage_exit_creation(df, ep_str, candles_df_pd, max_candles):
    cdef tuple candles_index = tuple(candles_df_pd.index)
    cdef tuple candles_df = tuple(tuple(x) for x in candles_df_pd.itertuples())
    cdef list raw_df = []
    cdef list index = []
    cdef datetime dt
    cdef double close
    cdef double entry_point
    cdef double exit_point

    for dt, close, entry_point, exit_point in (tuple(x) for x in df.itertuples()):
        pos = bisect.bisect_left(candles_index, dt)
        x = candles_df[pos:pos+max_candles]
        raw_df.append(create_exits(dt, close, entry_point, exit_point, ep_str, x))
        index.append(dt)

    return pd.DataFrame(raw_df, index=index)

def create_exits(datetime dt, double close, double entry_point, double exitp, str exit_str, tuple remaining):
    """
    Calculate exit datetime for each possible exit point.

    :param df_line: Input df_line

    :return: pd.Series([Hora da Saida, Saldo])
    """

    if exitp < 0:
        exitp = exitp * -1

    # Evaluate if it is stop or not
    is_stop = 'stop' in exit_str

    # Evaluate if alta ou baixa
    is_high = close < exitp

    # Checks if it is not the last value
    if len(remaining) < 2:
        # Need to return series as this outputs a DataFrame when used in a DF.apply()
        return [np.datetime64('NaT'), 0.0]

    # Iter through DataFrame to find exit

    cdef datetime index
    cdef double open
    cdef double high
    cdef double low

    index, open, high, low = remaining[1]

    # Routine if high
    if is_high:
        if open >= exitp:
            return [np.datetime64('NaT'), -1000.0]

    # Routine if low
    else:
        if open <= exitp:
            return [np.datetime64('NaT'), -1000.0]

    # Iter through DataFrame to find exit
    for index, open, high, low in remaining[1:]:

        # Routine if high
        if is_high:
            if high >= exitp:
                exitp = max(open, exitp)
                saldo = exitp - entry_point

                if is_stop:
                    saldo = saldo * -1
                return [index, saldo]

        # Routine if low
        else:
            if low <= exitp:
                exitp = min(open, exitp)
                saldo = entry_point - exitp

                if is_stop:
                    saldo = saldo * -1
                return [index, saldo]

    # If no values found returns blank
    return [np.datetime64('NaT'), 0.0]

cdef void consolidate_exits(str asset, str entry, object exits, bint is_dentro):
    """
    Run exit consolidation routine and saves it to disk.
    """
    # Sort DataFrame
    exits.sort_index(inplace=True)

    # Instantiates DataFrame
    cdef tuple col_names = tuple(exits.columns.values)
    cdef list output = []
    cdef datetime last_trade = None

    for row in exits.itertuples():
        last_trade, tmp = juntate_exits(last_trade, tuple(row), is_dentro, col_names)
        output.append(tmp)

    df = pd.DataFrame(output, index=exits.index)
    df.columns = ['exit_reference', 'exit_date', 'exit_saldo']

    # Sets filename
    filename = 'data/liquidation/' + asset + '_' + entry + '_CONSOLIDATE'

    # Save liquidation to disk
    save_liquidation_to_disk(filename, df)

cdef tuple juntate_exits(datetime last_trade, tuple df_line, bint is_dentro, tuple column_names):
    """
    Gets a DataFrame line and evaluate what exit will it be.

    :param df_line: Input DF Line
    :return: Output DF Line containing:
        1. 'exit_reference' - String
        2. 'exit_date' - DateTime
        3. 'exit_saldo' - Float
    :rtype: pandas Series
    """
    #  (Timestamp('2017-01-01 22:00:00'),
    #  a_doji_profit_dt      2017-01-05 05:19:00
    #  a_doji_profit_saldo   0.00301459
    #  a_doji_stop_dt         2017-01-02 09:01:00
    #  aa_doji_stop_saldo              -0.00329459
    #  entry                              1.05167

    # Dentro Routine
    if is_dentro and last_trade is not None and last_trade > df_line[0]:
        return last_trade, ['', np.datetime64('NaT'), 0]

    if check_if_invalid_entry(df_line):
        return last_trade, ['', np.datetime64('NaT'), 0]

    dt_min = None
    # Select only dates
    for i, dt in enumerate(df_line[1:]):
        if isinstance(dt, datetime):
            if dt.value > 0:
                if dt_min is None or dt < dt_min:
                    dt_min = dt
                    saldo_min = df_line[i + 2]
                    col_name = column_names[i]

    # If dates returns empty return empty
    if dt_min is None:
        return last_trade, ['', np.datetime64('NaT'), 0]

    # Generates output# TODO use named tuples to get 'nome da saida'
    return dt_min, [col_name[:-3], dt_min, saldo_min]

cdef check_if_invalid_entry(df_line):
    if not any(i == -1000.0 for i in df_line):
        return False
    else:
        for i, el in enumerate(df_line):
            if el == -1000.0:
                if not df_line[i - 1].value > 0:
                    return True
    return False

def save_liquidation_to_disk(filename, df):
    """
    Saves liquidation to disk in HDF5 format.

    :param filename: Selects filename to be saved
    :param df: DataFrame to be saved
    """
    # Remove liquidation File if exists
    if os.path.isfile(filename):
        os.unlink(filename)

    # Save liquidations to disk
    with pd.HDFStore(filename) as hdf:
        hdf.append(key='liquidation', value=df, format='table', data_columns=True)

def virada(df):
    # TODO virada is dependent on column order. improve this.
    output = []
    for index_a, close_a, ep_a, profit_a, stop_a in df.itertuples():
        for index_b, close_b, ep_b, profit_b, stop_b in df[index_a:].itertuples():
            if stop_a > 0:
                if stop_b < 0:
                    output.append([index_b, ep_b - ep_a, ep_a])
                    break
            else:
                if stop_b > 0:
                    output.append([index_b, ep_a - ep_b, ep_a])
                    break
        else:
            output.append([np.datetime64('NaT'), 0.0, ep_a])

    return pd.DataFrame(output, index=df.index, columns=['virada_dt', 'virada_saldo', 'entry'])
