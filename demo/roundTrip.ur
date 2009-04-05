table channels : { Client : client, Channel : channel (string * int * float) }

fun writeBack v =
    me <- self;
    r <- oneRow (SELECT channels.Channel FROM channels WHERE channels.Client = {[me]});
    send r.Channels.Channel v

fun main () =
    me <- self;
    ch <- channel;
    dml (INSERT INTO channels (Client, Channel) VALUES ({[me]}, {[ch]}));
    
    buf <- Buffer.create;

    let
        fun receiver () =
            v <- recv ch;
            Buffer.write buf ("(" ^ v.1 ^ ", " ^ show v.2 ^ ", " ^ show v.3 ^ ")");
            receiver ()

        fun sender s n f =
            sleep 2000;
            writeBack (s, n, f);
            sender (s ^ "!") (n + 1) (f + 1.23)
    in
        return <xml><body onload={spawn (receiver ()); sender "" 0 0.0}>
          <dyn signal={Buffer.render buf}/>
        </body></xml>
    end
