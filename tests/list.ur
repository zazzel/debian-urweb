fun isNil (t ::: Type) (ls : list t) =
    case ls of
        Nil => True
      | _ => False

fun delist (ls : list string) : xbody =
        case ls of
            Nil => <xml>Nil</xml>
          | Cons (h, t) => <xml>{[h]} :: {delist t}</xml>

fun callback ls = return <xml><body>
  {delist ls}
</body></xml>

fun main () = return <xml><body>
  {[isNil (Nil : list bool)]},
  {[isNil (Cons (1, Nil))]},
  {[isNil (Cons ("A", Cons ("B", Nil)))]}

  <p>{delist (Cons ("X", Cons ("Y", Cons ("Z", Nil))))}</p>
  <a link={callback (Cons ("A", Cons ("B", Nil)))}>Go!</a>
</body></xml>
