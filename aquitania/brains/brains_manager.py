########################################################################################################################
# |||||||||||||||||||||||||||||||||||||||||||||||||| AQUITANIA ||||||||||||||||||||||||||||||||||||||||||||||||||||||||#
# |||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||#
# |||| To be a thinker means to go by the factual evidence of a case, not by the judgment of others |||||||||||||||||||#
# |||| As there is no group stomach to digest collectively, there is no group mind to think collectively. |||||||||||||#
# |||| Each man must accept responsibility for his own life, each must be sovereign by his own judgment. ||||||||||||||#
# |||| If a man believes a claim to be true, then he must hold to this belief even though society opposes him. ||||||||#
# |||| Not only know what you want, but be willing to break all established conventions to accomplish it. |||||||||||||#
# |||| The merit of a design is the only credential that you require. |||||||||||||||||||||||||||||||||||||||||||||||||#
# |||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||#
########################################################################################################################

"""
.. moduleauthor:: H Roark

I am not sure when I first created Abstract classes for model_manager and etc, but it was likely to be around February 2018.

Now it is May 1st of 2018, and I decided to go for a full refactor of the Brains Module. I'll create a Model Abstract
class that will handle ensembles and other more complicated structures inside it and that will behave just as like a
simpler model_manager would on its outside world methods.

I will also create the possibility to work with splitting into Train, Test, and Validation Data, and working to make a
automatic grid search for it.
"""
from aquitania.execution.oracle import Oracle
from brains.is_oos_split.train_test_split import TrainTestSplit
from brains.model_manager import ModelManager
from aquitania.data_processing import IndicatorTransformer
import _pickle as cPickle


class BrainsManager:
    def __init__(self, broker_instance, list_of_currencies, strategy):
        # Set attributes
        self.broker_instance = broker_instance
        self.list_of_currencies = list_of_currencies
        self.strategy = strategy
        self.transformer = IndicatorTransformer(self.broker_instance, strategy.signal)

    def run_model(self, model):
        X, y, y_pips = self.prepare_data()

        is_oos_selector = TrainTestSplit({'test_size': 0.15})

        model_manager = ModelManager(model, is_oos_selector, self.transformer)

        model_results = model_manager.fit_predict_evaluate(X, y)

        features = X.columns

        self.save_strategy_to_disk(model_manager, features, *model_results)

    def prepare_data(self):
        # Gets Raw Data
        X = build_ai_df(self.broker_instance, self.list_of_currencies, self.strategy.signal.entry)

        # Print DataFrame size
        print('original DataFrame size:', X.shape)

        # Get results set
        y = self.generate_results_set(self.strategy.signal.entry)

        # Transform
        transformed_df = self.transformer.transform(X, y)

        # Return transformed_df
        return transformed_df

    def generate_results_set(self, signal):
        results_set = None
        # Load results set
        for currency in self.list_of_currencies:
            if results_set is None:
                results_set = pd.read_hdf('data/liquidation/' + currency + '_' + signal + '_CONSOLIDATE')
            else:
                temp_df = pd.read_hdf('data/liquidation/' + currency + '_' + signal + '_CONSOLIDATE')
                results_set = pd.concat([results_set, temp_df])

        return results_set

    def save_strategy_to_disk(self, model_manager, features, bet_sizing_dict, i_bet_sizing_dict):
        """
        Pickles all the required strategy elements to make it work on the LiveEnvironment and make decisions about which
        trades are valid and which aren't.

        :param model_manager: (ModelManager) which is used to make predictions
        :param features: (list) of features that are being utilized to generate predictions
        :param bet_sizing_dict: (pandas DataFrame) Bet Sizing Dictionary for Ratio
        :param i_bet_sizing_dict: (pandas DataFrame) Bet Sizing Dictionary for Inverse Ratio
        """
        # Instantiates Oracle object (Object that makes predictions)
        oracle = Oracle(self.strategy.signal, model_manager, features, self.transformer, bet_sizing_dict,
                        i_bet_sizing_dict)

        # Saves Oracle into Disk
        with open('data/model_manager/{}.pkl'.format(self.strategy.__class__.__name__), 'wb') as f:
            cPickle.dump(oracle, f)