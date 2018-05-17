import os
import sys
from flask import Flask, request, abort 
import traceback
from custodian.utils import *
from custodian import config
import json
import datetime

def verify_request(msg_json):
    # TODO: To be made more sophisticated later
    if 'method' in msg_json:
        if msg_json['method'] == 'init_sbtc2ebtc':
            return True
    else:
        return False 

def create_app(test_config=None):
    # create and configure the app
    app = Flask(__name__, instance_relative_config=True)
    app.config.from_mapping(
        SECRET_KEY='dev',
        DATABASE=os.path.join(app.instance_path, 'flaskr.sqlite'),
    )

    if test_config is None:
        # load the instance config, if it exists, when not testing
        app.config.from_pyfile('config.py', silent=True)
    else:
        # load the test config if passed in
        app.config.from_mapping(test_config)

    # ensure the instance folder exists
    try:
        os.makedirs(app.instance_path)
    except OSError:
        pass

    logger = init_logger('STRIDE', '/tmp/stride.log')
    event_q = RabbitMQ('custodian-q')
    eth = W3Utils(config.eth, logger)
    rsk = W3Utils(config.rsk, logger) 
    
    @app.route('/stride', methods=['POST'])
    def stride():
        try:
           if not request.json:
               logger.info('Request does not have json')
               abort(400) 
           js = json.loads(request.json)
           if verify_request(js):           
               pwd_str, pwd_hash = eth.generate_random_string(4)
               js['pwd'] = pwd_str
               js['pwd_hash'] = pwd_hash.hex()
               js['date'] = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%S')
               event_q.send(json.dumps(js))
               return_msg = json.dumps({'jsonrpc': '2.0', 
                                        'result': pwd_hash.hex(),
                                        'id' : js['id']}) 
               print('Returning success msg')
               return return_msg 
           else:
               print('Returning error msg')
               error_msg = json.dumps({'jsonrpc': '2.0', 'error' : {'code' : 1, 'message' : 'Unknow method'}, 'id' : js['id']})        
               return error_msg
        except:
           exc_type, exc_value, exc_tb = sys.exc_info()
           logger.error(repr(traceback.format_exception(exc_type, exc_value,
                                          exc_tb)))
           abort(400)

    return app

app = create_app()