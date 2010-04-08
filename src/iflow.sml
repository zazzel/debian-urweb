(* Copyright (c) 2010, Adam Chlipala
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * - Redistributions of source code must retain the above copyright notice,
 *   this list of conditions and the following disclaimer.
 * - Redistributions in binary form must reproduce the above copyright notice,
 *   this list of conditions and the following disclaimer in the documentation
 *   and/or other materials provided with the distribution.
 * - The names of contributors may not be used to endorse or promote products
 *   derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR 
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 *)

structure Iflow :> IFLOW = struct

open Mono

structure IS = IntBinarySet
structure IM = IntBinaryMap

structure SS = BinarySetFn(struct
                           type ord_key = string
                           val compare = String.compare
                           end)

val writers = ["htmlifyInt_w",
               "htmlifyFloat_w",
               "htmlifyString_w",
               "htmlifyBool_w",
               "htmlifyTime_w",
               "attrifyInt_w",
               "attrifyFloat_w",
               "attrifyString_w",
               "attrifyChar_w",
               "urlifyInt_w",
               "urlifyFloat_w",
               "urlifyString_w",
               "urlifyBool_w",
               "set_cookie"]

val writers = SS.addList (SS.empty, writers)

type lvar = int

datatype exp =
         Const of Prim.t
       | Var of int
       | Lvar of lvar
       | Func of string * exp list
       | Recd of (string * exp) list
       | Proj of exp * string
       | Finish

datatype reln =
         Known
       | Sql of string
       | DtCon of string
       | Eq
       | Ne
       | Lt
       | Le
       | Gt
       | Ge

datatype prop =
         True
       | False
       | Unknown
       | And of prop * prop
       | Or of prop * prop
       | Reln of reln * exp list
       | Cond of exp * prop

local
    open Print
    val string = PD.string
in

fun p_exp e =
    case e of
        Const p => Prim.p_t p
      | Var n => string ("x" ^ Int.toString n)
      | Lvar n => string ("X" ^ Int.toString n)
      | Func (f, es) => box [string (f ^ "("),
                             p_list p_exp es,
                             string ")"]
      | Recd xes => box [string "{",
                         p_list (fn (x, e) => box [string x,
                                                   space,
                                                   string "=",
                                                   space,
                                                   p_exp e]) xes,
                         string "}"]
      | Proj (e, x) => box [p_exp e,
                            string ("." ^ x)]
      | Finish => string "FINISH"

fun p_bop s es =
    case es of
        [e1, e2] => box [p_exp e1,
                         space,
                         string s,
                         space,
                         p_exp e2]
      | _ => raise Fail "Iflow.p_bop"

fun p_reln r es =
    case r of
        Known =>
        (case es of
             [e] => box [string "known(",
                         p_exp e,
                         string ")"]
           | _ => raise Fail "Iflow.p_reln: Known")
      | Sql s => box [string (s ^ "("),
                      p_list p_exp es,
                      string ")"]
      | DtCon s => box [string (s ^ "("),
                        p_list p_exp es,
                        string ")"]
      | Eq => p_bop "=" es
      | Ne => p_bop "<>" es
      | Lt => p_bop "<" es
      | Le => p_bop "<=" es
      | Gt => p_bop ">" es
      | Ge => p_bop ">=" es

fun p_prop p =
    case p of
        True => string "True"
      | False => string "False"
      | Unknown => string "??"
      | And (p1, p2) => box [string "(",
                             p_prop p1,
                             string ")",
                             space,
                             string "&&",
                             space,
                             string "(",
                             p_prop p2,
                             string ")"]
      | Or (p1, p2) => box [string "(",
                            p_prop p1,
                            string ")",
                            space,
                            string "||",
                            space,
                            string "(",
                            p_prop p2,
                            string ")"]
      | Reln (r, es) => p_reln r es
      | Cond (e, p) => box [string "(",
                            p_exp e,
                            space,
                            string "==",
                            space,
                            p_prop p,
                            string ")"]

end

local
    val count = ref 1
in
fun newLvar () =
    let
        val n = !count
    in
        count := n + 1;
        n
    end
end

fun isKnown e =
    case e of
        Const _ => true
      | Func (_, es) => List.all isKnown es
      | Recd xes => List.all (isKnown o #2) xes
      | Proj (e, _) => isKnown e
      | _ => false

fun isFinish e =
    case e of
        Finish => true
      | _ => false

val unif = ref (IM.empty : exp IM.map)

fun reset () = unif := IM.empty
fun save () = !unif
fun restore x = unif := x

fun simplify e =
    case e of
        Const _ => e
      | Var _ => e
      | Lvar n =>
        (case IM.find (!unif, n) of
             NONE => e
           | SOME e => simplify e)
      | Func (f, es) =>
        let
            val es = map simplify es

            fun default () = Func (f, es)
        in
            if List.exists isFinish es then
                Finish
            else if String.isPrefix "un" f then
                case es of
                    [Func (f', [e])] => if f' = String.extract (f, 2, NONE) then
                                            e
                                        else
                                            default ()
                  | _ => default ()
            else
                default ()
        end
      | Recd xes =>
        let
            val xes = map (fn (x, e) => (x, simplify e)) xes
        in
            if List.exists (isFinish o #2) xes then
                Finish
            else
                Recd xes
        end
      | Proj (e, s) =>
        (case simplify e of
             Recd xes =>
             getOpt (ListUtil.search (fn (x, e') => if x = s then SOME e' else NONE) xes, Recd xes)
           | e' =>
             if isFinish e' then
                 Finish
             else
                 Proj (e', s))
      | Finish => Finish

datatype atom =
         AReln of reln * exp list
       | ACond of exp * prop

fun p_atom a =
    p_prop (case a of
                AReln x => Reln x
              | ACond x => Cond x)

fun decomp fals or =
    let
        fun decomp p k =
            case p of
                True => k []
              | False => fals
              | Unknown => k []
              | And (p1, p2) => 
                decomp p1 (fn ps1 =>
                              decomp p2 (fn ps2 =>
                                            k (ps1 @ ps2)))
              | Or (p1, p2) =>
                or (decomp p1 k, fn () => decomp p2 k)
              | Reln x => k [AReln x]
              | Cond x => k [ACond x]
    in
        decomp
    end

fun lvarIn lv =
    let
        fun lvi e =
            case e of
                Const _ => false
              | Var _ => false
              | Lvar lv' => lv' = lv
              | Func (_, es) => List.exists lvi es
              | Recd xes => List.exists (lvi o #2) xes
              | Proj (e, _) => lvi e
              | Finish => false
    in
        lvi
    end

fun lvarInP lv =
    let
        fun lvi p =
            case p of
                True => false
              | False => false
              | Unknown => true
              | And (p1, p2) => lvi p1 orelse lvi p2
              | Or (p1, p2) => lvi p1 orelse lvi p2
              | Reln (_, es) => List.exists (lvarIn lv) es
              | Cond (e, p) => lvarIn lv e orelse lvi p
    in
        lvi
    end

fun varIn lv =
    let
        fun lvi e =
            case e of
                Const _ => false
              | Lvar _ => false
              | Var lv' => lv' = lv
              | Func (_, es) => List.exists lvi es
              | Recd xes => List.exists (lvi o #2) xes
              | Proj (e, _) => lvi e
              | Finish => false
    in
        lvi
    end

fun varInP lv =
    let
        fun lvi p =
            case p of
                True => false
              | False => false
              | Unknown => false
              | And (p1, p2) => lvi p1 orelse lvi p2
              | Or (p1, p2) => lvi p1 orelse lvi p2
              | Reln (_, es) => List.exists (varIn lv) es
              | Cond (e, p) => varIn lv e orelse lvi p
    in
        lvi
    end

fun eq' (e1, e2) =
    case (e1, e2) of
        (Const p1, Const p2) => Prim.equal (p1, p2)
      | (Var n1, Var n2) => n1 = n2

      | (Lvar n1, _) =>
        (case IM.find (!unif, n1) of
             SOME e1 => eq' (e1, e2)
           | NONE =>
             case e2 of
                 Lvar n2 =>
                 (case IM.find (!unif, n2) of
                      SOME e2 => eq' (e1, e2)
                    | NONE => n1 = n2
                              orelse (unif := IM.insert (!unif, n2, e1);
                                      true))
               | _ =>
                 if lvarIn n1 e2 then
                     false
                 else
                     (unif := IM.insert (!unif, n1, e2);
                      true))

      | (_, Lvar n2) =>
        (case IM.find (!unif, n2) of
             SOME e2 => eq' (e1, e2)
           | NONE =>
             if lvarIn n2 e1 then
                 false
             else
                 ((*Print.prefaces "unif" [("n2", Print.PD.string (Int.toString n2)),
                                         ("e1", p_exp e1)];*)
                  unif := IM.insert (!unif, n2, e1);
                  true))
                                       
      | (Func (f1, es1), Func (f2, es2)) => f1 = f2 andalso ListPair.allEq eq' (es1, es2)
      | (Recd xes1, Recd xes2) => ListPair.allEq (fn ((x1, e1), (x2, e2)) => x1 = x2 andalso eq' (e1, e2)) (xes1, xes2)
      | (Proj (e1, s1), Proj (e2, s2)) => eq' (e1, e2) andalso s1 = s2
      | (Finish, Finish) => true
      | _ => false

fun eq (e1, e2) =
    let
        val saved = save ()
    in
        if eq' (simplify e1, simplify e2) then
            true
        else
            (restore saved;
             false)
    end

val debug = ref false

fun eeq (e1, e2) =
    case (e1, e2) of
        (Const p1, Const p2) => Prim.equal (p1, p2)
      | (Var n1, Var n2) => n1 = n2
      | (Lvar n1, Lvar n2) => n1 = n2
      | (Func (f1, es1), Func (f2, es2)) => f1 = f2 andalso ListPair.allEq eeq (es1, es2)
      | (Recd xes1, Recd xes2) => length xes1 = length xes2 andalso
                                  List.all (fn (x2, e2) =>
                                               List.exists (fn (x1, e1) => x1 = x2 andalso eeq (e1, e2)) xes2) xes1
      | (Proj (e1, x1), Proj (e2, x2)) => eeq (e1, e2) andalso x1 = x2
      | (Finish, Finish) => true
      | _ => false
             
(* Congruence closure *)
structure Cc :> sig
    type t
    val empty : t
    val assert : t * exp * exp -> t
    val query : t * exp * exp -> bool
    val allPeers : t * exp -> exp list
    val p_t : t Print.printer
end = struct

fun eq (e1, e2) = eeq (simplify e1, simplify e2)

type t = (exp * exp) list

val empty = []

fun lookup (t, e) =
    case List.find (fn (e', _) => eq (e', e)) t of
        NONE => e
      | SOME (_, e2) => lookup (t, e2)

fun allPeers (t, e) =
    let
        val r = lookup (t, e)
    in
        r :: List.mapPartial (fn (e1, e2) =>
                                 let
                                     val r' = lookup (t, e2)
                                 in
                                     if eq (r, r') then
                                         SOME e1
                                     else
                                         NONE
                                 end) t
    end

open Print

val p_t = p_list (fn (e1, e2) => box [p_exp (simplify e1),
                                      space,
                                      PD.string "->",
                                      space,
                                      p_exp (simplify e2)])

fun query (t, e1, e2) =
    let
        fun doUn e =
            case e of
                Func (f, [e1]) =>
                if String.isPrefix "un" f then
                    let
                        val s = String.extract (f, 2, NONE)
                    in
                        case ListUtil.search (fn e =>
                                                 case e of
                                                     Func (f', [e']) =>
                                                     if f' = s then
                                                         SOME e'
                                                     else
                                                         NONE
                                                   | _ => NONE) (allPeers (t, e1)) of
                            NONE => e
                          | SOME e => doUn e
                    end
                else
                    e
              | _ => e

        val e1' = doUn (lookup (t, doUn (simplify e1)))
        val e2' = doUn (lookup (t, doUn (simplify e2)))
    in
        (*prefaces "CC query" [("e1", p_exp (simplify e1)),
                             ("e2", p_exp (simplify e2)),
                             ("e1'", p_exp (simplify e1')),
                             ("e2'", p_exp (simplify e2')),
                             ("t", p_t t)];*)
        eq (e1', e2')
    end

fun assert (t, e1, e2) =
    let
        val r1 = lookup (t, e1)
        val r2 = lookup (t, e2)
    in
        if eq (r1, r2) then
            t
        else
            let
                fun doUn (t, e1, e2) =
                    case e1 of
                        Func (f, [e]) => if String.isPrefix "un" f then
                                             let
                                                 val s = String.extract (f, 2, NONE)
                                             in
                                                 foldl (fn (e', t) =>
                                                           case e' of
                                                               Func (f', [e']) =>
                                                               if f' = s then
                                                                   assert (assert (t, e', e1), e', e2)
                                                               else
                                                                   t
                                                             | _ => t) t (allPeers (t, e))
                                             end
                                         else
                                             t
                      | _ => t

                fun doProj (t, e1, e2) =
                    foldl (fn ((e1', e2'), t) =>
                              let
                                  fun doOne (e, t) =
                                      case e of
                                          Proj (e', f) =>
                                          if query (t, e1, e') then
                                              assert (t, e, Proj (e2, f))
                                          else
                                              t
                                        | _ => t
                              in
                                  doOne (e1', doOne (e2', t))
                              end) t t

                val t = (r1, r2) :: t
                val t = doUn (t, r1, r2)
                val t = doUn (t, r2, r1)
                val t = doProj (t, r1, r2)
                val t = doProj (t, r2, r1)
            in
                t
            end
    end

end

fun rimp cc ((r1, es1), (r2, es2)) =
    case (r1, r2) of
        (Sql r1', Sql r2') =>
        r1' = r2' andalso
        (case (es1, es2) of
             ([e1], [e2]) => eq (e1, e2)
           | _ => false)
      | (Eq, Eq) =>
        (case (es1, es2) of
             ([x1, y1], [x2, y2]) =>
             let
                 val saved = save ()
             in
                 if eq (x1, x2) andalso eq (y1, y2) then
                     true
                 else
                     (restore saved;
                      if eq (x1, y2) andalso eq (y1, x2) then
                          true
                      else
                          (restore saved;
                           false))
             end
           | _ => false)
      | (Known, Known) =>
        (case (es1, es2) of
             ([Var v], [e2]) =>
             let
                 fun matches e =
                     case e of
                         Var v' => v' = v
                       | Proj (e, _) => matches e
                       | Func (f, [e]) => String.isPrefix "un" f andalso matches e
                       | _ => false
             in
                 (*Print.prefaces "Checking peers" [("e2", p_exp e2),
                                                  ("peers", Print.p_list p_exp (Cc.allPeers (cc, e2))),
                                                  ("db", Cc.p_t cc)];*)
                 List.exists matches (Cc.allPeers (cc, e2))
             end
           | _ => false)
      | _ => false

fun imply (p1, p2) =
    let
        fun doOne doKnown =
            decomp true (fn (e1, e2) => e1 andalso e2 ()) p1
                   (fn hyps =>
                       decomp false (fn (e1, e2) => e1 orelse e2 ()) p2
                              (fn goals =>
                                  let
                                      val cc = foldl (fn (p, cc) =>
                                                         case p of
                                                             AReln (Eq, [e1, e2]) => Cc.assert (cc, e1, e2)
                                                           | _ => cc) Cc.empty hyps

                                      fun gls goals onFail =
                                          case goals of
                                              [] => true
                                            | ACond _ :: _ => false
                                            | AReln g :: goals =>
                                              case (doKnown, g) of
                                                  (false, (Known, _)) => gls goals onFail
                                                | _ =>
                                                  let
                                                      fun hps hyps =
                                                          case hyps of
                                                              [] => ((*Print.prefaces "Fail" [("g", p_prop (Reln g)),
                                                                                            ("db", Cc.p_t cc)];*)
                                                                     onFail ())
                                                            | ACond _ :: hyps => hps hyps
                                                            | AReln h :: hyps =>
                                                              let
                                                                  val saved = save ()
                                                              in
                                                                  if rimp cc (h, g) then
                                                                      let
                                                                          val changed = IM.numItems (!unif)
                                                                                        <> IM.numItems saved
                                                                      in
                                                                          gls goals (fn () => (restore saved;
                                                                                               changed (*andalso 
                                                                                               (Print.preface ("Retry",
                                                                                                               p_prop
                                                                                                                   (Reln g)
                                                                                                              ); true)*)
                                                                                               andalso hps hyps))
                                                                      end
                                                                  else
                                                                      hps hyps
                                                              end
                                                  in
                                                      (case g of
                                                           (Eq, [e1, e2]) => Cc.query (cc, e1, e2)
                                                         | _ => false)
                                                      orelse hps hyps
                                                  end
                                  in
                                      if List.exists (fn AReln (DtCon c1, [e]) =>
                                                         List.exists (fn AReln (DtCon c2, [e']) =>
                                                                         c1 <> c2 andalso
                                                                         Cc.query (cc, e, e')
                                                                       | _ => false) hyps
                                                         orelse List.exists (fn Func (c2, []) => c1 <> c2
                                                                              | Finish => true
                                                                              | _ => false)
                                                                            (Cc.allPeers (cc, e))
                                                       | _ => false) hyps
                                         orelse gls goals (fn () => false) then
                                          true
                                      else
                                          ((*Print.prefaces "Can't prove"
                                                          [("hyps", Print.p_list p_atom hyps),
                                                           ("goals", Print.p_list p_atom goals)];*)
                                           false)
                                  end))
    in
        reset ();
        doOne false;
        doOne true
    end

fun patCon pc =
    case pc of
        PConVar n => "C" ^ Int.toString n
      | PConFfi {mod = m, datatyp = d, con = c, ...} => m ^ "." ^ d ^ "." ^ c

datatype chunk =
         String of string
       | Exp of Mono.exp

fun chunkify e =
    case #1 e of
        EPrim (Prim.String s) => [String s]
      | EStrcat (e1, e2) =>
        let
            val chs1 = chunkify e1
            val chs2 = chunkify e2
        in
            case chs2 of
                String s2 :: chs2' =>
                (case List.last chs1 of
                     String s1 => List.take (chs1, length chs1 - 1) @ String (s1 ^ s2) :: chs2'
                   | _ => chs1 @ chs2)
              | _ => chs1 @ chs2
        end
      | _ => [Exp e]

type 'a parser = chunk list -> ('a * chunk list) option

fun always v chs = SOME (v, chs)

fun parse p s =
    case p (chunkify s) of
        SOME (v, []) => SOME v
      | _ => NONE

fun const s chs =
    case chs of
        String s' :: chs => if String.isPrefix s s' then
                                SOME ((), if size s = size s' then
                                              chs
                                          else
                                              String (String.extract (s', size s, NONE)) :: chs)
                            else
                                NONE
      | _ => NONE

fun follow p1 p2 chs =
    case p1 chs of
        NONE => NONE
      | SOME (v1, chs) =>
        case p2 chs of
            NONE => NONE
          | SOME (v2, chs) => SOME ((v1, v2), chs)

fun wrap p f chs =
    case p chs of
        NONE => NONE
      | SOME (v, chs) => SOME (f v, chs)

fun wrapP p f chs =
    case p chs of
        NONE => NONE
      | SOME (v, chs) =>
        case f v of
            NONE => NONE
          | SOME r => SOME (r, chs)

fun alt p1 p2 chs =
    case p1 chs of
        NONE => p2 chs
      | v => v

fun altL ps =
    case rev ps of
        [] => (fn _ => NONE)
      | p :: ps =>
        foldl (fn (p1, p2) => alt p1 p2) p ps

fun opt p chs =
    case p chs of
        NONE => SOME (NONE, chs)
      | SOME (v, chs) => SOME (SOME v, chs)

fun skip cp chs =
    case chs of
        String "" :: chs => skip cp chs
      | String s :: chs' => if cp (String.sub (s, 0)) then
                                skip cp (String (String.extract (s, 1, NONE)) :: chs')
                            else
                                SOME ((), chs)
      | _ => SOME ((), chs)

fun keep cp chs =
    case chs of
        String "" :: chs => keep cp chs
      | String s :: chs' =>
        let
            val (befor, after) = Substring.splitl cp (Substring.full s)
        in
            if Substring.isEmpty befor then
                NONE
            else
                SOME (Substring.string befor,
                      if Substring.isEmpty after then
                          chs'
                      else
                          String (Substring.string after) :: chs')
        end
      | _ => NONE

fun ws p = wrap (follow (skip (fn ch => ch = #" "))
                        (follow p (skip (fn ch => ch = #" ")))) (#1 o #2)

fun log name p chs =
    (if !debug then
         case chs of
             String s :: _ => print (name ^ ": " ^ s ^ "\n")
           | _ => print (name ^ ": blocked!\n")
     else
         ();
     p chs)

fun list p chs =
    altL [wrap (follow p (follow (ws (const ",")) (list p)))
               (fn (v, ((), ls)) => v :: ls),
          wrap (ws p) (fn v => [v]),
          always []] chs

val ident = keep (fn ch => Char.isAlphaNum ch orelse ch = #"_")

val t_ident = wrapP ident (fn s => if String.isPrefix "T_" s then
                                       SOME (String.extract (s, 2, NONE))
                                   else
                                       NONE)
val uw_ident = wrapP ident (fn s => if String.isPrefix "uw_" s andalso size s >= 4 then
                                        SOME (str (Char.toUpper (String.sub (s, 3)))
                                              ^ String.extract (s, 4, NONE))
                                    else
                                        NONE)

val field = wrap (follow t_ident
                         (follow (const ".")
                                 uw_ident))
                 (fn (t, ((), f)) => (t, f))

datatype Rel =
         Exps of exp * exp -> prop
       | Props of prop * prop -> prop

datatype sqexp =
         SqConst of Prim.t
       | Field of string * string
       | Binop of Rel * sqexp * sqexp
       | SqKnown of sqexp
       | Inj of Mono.exp
       | SqFunc of string * sqexp
       | Count

fun cmp s r = wrap (const s) (fn () => Exps (fn (e1, e2) => Reln (r, [e1, e2])))

val sqbrel = altL [cmp "=" Eq,
                   cmp "<>" Ne,
                   cmp "<=" Le,
                   cmp "<" Lt,
                   cmp ">=" Ge,
                   cmp ">" Gt,
                   wrap (const "AND") (fn () => Props And),
                   wrap (const "OR") (fn () => Props Or)]

datatype ('a, 'b) sum = inl of 'a | inr of 'b

fun string chs =
    case chs of
        String s :: chs =>
        if size s >= 2 andalso String.sub (s, 0) = #"'" then
            let
                fun loop (cs, acc) =
                    case cs of
                        [] => NONE
                      | c :: cs =>
                        if c = #"'" then
                            SOME (String.implode (rev acc), cs)
                        else if c = #"\\" then
                            case cs of
                                c :: cs => loop (cs, c :: acc)
                              | _ => raise Fail "Iflow.string: Unmatched backslash escape"
                        else
                            loop (cs, c :: acc)
            in
                case loop (String.explode (String.extract (s, 1, NONE)), []) of
                    NONE => NONE
                  | SOME (s, []) => SOME (s, chs)
                  | SOME (s, cs) => SOME (s, String (String.implode cs) :: chs)
            end
        else
            NONE
      | _ => NONE                            

val prim =
    altL [wrap (follow (wrapP (follow (keep Char.isDigit) (follow (const ".") (keep Char.isDigit)))
                              (fn (x, ((), y)) => Option.map Prim.Float (Real64.fromString (x ^ "." ^ y))))
                       (opt (const "::float8"))) #1,
          wrap (follow (wrapP (keep Char.isDigit)
                              (Option.map Prim.Int o Int64.fromString))
                       (opt (const "::int8"))) #1,
          wrap (follow (opt (const "E")) (follow string (opt (const "::text"))))
               (Prim.String o #1 o #2)]

fun known' chs =
    case chs of
        Exp (EFfi ("Basis", "sql_known"), _) :: chs => SOME ((), chs)
      | _ => NONE

fun sqlify chs =
    case chs of
        Exp (EFfiApp ("Basis", f, [e]), _) :: chs =>
        if String.isPrefix "sqlify" f then
            SOME (e, chs)
        else
            NONE
      | _ => NONE

fun constK s = wrap (const s) (fn () => s)

val funcName = altL [constK "COUNT",
                     constK "MIN",
                     constK "MAX",
                     constK "SUM",
                     constK "AVG"]

fun sqexp chs =
    log "sqexp"
    (altL [wrap prim SqConst,
           wrap field Field,
           wrap known SqKnown,
           wrap func SqFunc,
           wrap (const "COUNT(*)") (fn () => Count),
           wrap sqlify Inj,
           wrap (follow (const "COALESCE(") (follow sqexp (follow (const ",")
                                                                  (follow (keep (fn ch => ch <> #")")) (const ")")))))
                (fn ((), (e, _)) => e),
           wrap (follow (ws (const "("))
                        (follow (wrap
                                     (follow sqexp
                                             (alt
                                                  (wrap
                                                       (follow (ws sqbrel)
                                                               (ws sqexp))
                                                       inl)
                                                  (always (inr ()))))
                                     (fn (e1, sm) =>
                                         case sm of
                                             inl (bo, e2) => Binop (bo, e1, e2)
                                           | inr () => e1))
                                (const ")")))
                (fn ((), (e, ())) => e)])
    chs

and known chs = wrap (follow known' (follow (const "(") (follow sqexp (const ")"))))
                     (fn ((), ((), (e, ()))) => e) chs
                
and func chs = wrap (follow funcName (follow (const "(") (follow sqexp (const ")"))))
                    (fn (f, ((), (e, ()))) => (f, e)) chs

datatype sitem =
         SqField of string * string
       | SqExp of sqexp * string

val sitem = alt (wrap field SqField)
            (wrap (follow sqexp (follow (const " AS ") uw_ident))
             (fn (e, ((), s)) => SqExp (e, s)))

val select = log "select"
             (wrap (follow (const "SELECT ") (list sitem))
                   (fn ((), ls) => ls))

val fitem = wrap (follow uw_ident
                         (follow (const " AS ")
                                 t_ident))
                 (fn (t, ((), f)) => (t, f))

val from = log "from"
           (wrap (follow (const "FROM ") (list fitem))
                 (fn ((), ls) => ls))

val wher = wrap (follow (ws (const "WHERE ")) sqexp)
           (fn ((), ls) => ls)

val query = log "query"
                (wrap (follow (follow select from) (opt wher))
                      (fn ((fs, ts), wher) => {Select = fs, From = ts, Where = wher}))

fun removeDups ls =
    case ls of
        [] => []
      | x :: ls =>
        let
            val ls = removeDups ls
        in
            if List.exists (fn x' => x' = x) ls then
                ls  
            else
                x :: ls
        end

datatype queryMode =
         SomeCol of exp
       | AllCols of exp

fun queryProp env rvN rv oe e =
    case parse query e of
        NONE => (print ("Warning: Information flow checker can't parse SQL query at "
                        ^ ErrorMsg.spanToString (#2 e) ^ "\n");
                 (rvN, Var 0, Unknown, []))
      | SOME r =>
        let
            val (rvN, count) = rv rvN

            val (rvs, rvN) = ListUtil.foldlMap (fn ((_, v), rvN) =>
                                                   let
                                                       val (rvN, e) = rv rvN
                                                   in
                                                       ((v, e), rvN)
                                                   end) rvN (#From r)

            fun rvOf v =
                case List.find (fn (v', _) => v' = v) rvs of
                    NONE => raise Fail "Iflow.queryProp: Bad table variable"
                  | SOME (_, e) => e

            fun usedFields e =
                case e of
                    SqConst _ => []
                  | Field (v, f) => [(v, f)]
                  | Binop (_, e1, e2) => removeDups (usedFields e1 @ usedFields e2)
                  | SqKnown _ => []
                  | Inj _ => []
                  | SqFunc (_, e) => usedFields e
                  | Count => []

            val p =
                foldl (fn ((t, v), p) => And (p, Reln (Sql t, [rvOf v]))) True (#From r)

            fun expIn e =
                case e of
                    SqConst p => inl (Const p)
                  | Field (v, f) => inl (Proj (rvOf v, f))
                  | Binop (bo, e1, e2) =>
                    inr (case (bo, expIn e1, expIn e2) of
                             (Exps f, inl e1, inl e2) => f (e1, e2)
                           | (Props f, inr p1, inr p2) => f (p1, p2)
                           | _ => Unknown)
                  | SqKnown e =>
                    inr (case expIn e of
                             inl e => Reln (Known, [e])
                           | _ => Unknown)
                  | Inj e =>
                    let
                        fun deinj (e, _) =
                            case e of
                                ERel n => List.nth (env, n)
                              | EField (e, f) => Proj (deinj e, f)
                              | _ => raise Fail "Iflow: non-variable injected into query"
                    in
                        inl (deinj e)
                    end
                  | SqFunc (f, e) =>
                    inl (case expIn e of
                         inl e => Func (f, [e])
                       | _ => raise Fail ("Iflow: non-expresion passed to function " ^ f))
                  | Count => inl count

            val p = case #Where r of
                        NONE => p
                      | SOME e =>
                        case expIn e of
                            inr p' => And (p, p')
                          | _ => p
        in
            (rvN,
             count,
             And (p, case oe of
                         SomeCol oe =>
                         foldl (fn (si, p) =>
                                   let
                                       val p' = case si of
                                                    SqField (v, f) => Reln (Eq, [oe, Proj (rvOf v, f)])
                                                  | SqExp (e, f) =>
                                                    case expIn e of
                                                        inr _ => Unknown
                                                      | inl e => Reln (Eq, [oe, e])
                                   in
                                       Or (p, p')
                                   end)
                               False (#Select r)
                       | AllCols oe =>
                         foldl (fn (si, p) =>
                                   let
                                       val p' = case si of
                                                    SqField (v, f) => Reln (Eq, [Proj (Proj (oe, v), f),
                                                                                 Proj (rvOf v, f)])
                                                  | SqExp (e, f) =>
                                                    case expIn e of
                                                        inr p => Cond (Proj (oe, f), p)
                                                      | inl e => Reln (Eq, [Proj (oe, f), e])
                                   in
                                       And (p, p')
                                   end)
                               True (#Select r)),
             
             case #Where r of
                 NONE => []
               | SOME e => map (fn (v, f) => Proj (rvOf v, f)) (usedFields e))
        end

fun evalPat env e (pt, _) =
    case pt of
        PWild => (env, True)
      | PVar _ => (e :: env, True)
      | PPrim _ => (env, True)
      | PCon (_, pc, NONE) => (env, Reln (DtCon (patCon pc), [e]))
      | PCon (_, pc, SOME pt) =>
        let
            val (env, p) = evalPat env (Func ("un" ^ patCon pc, [e])) pt
        in
            (env, And (p, Reln (DtCon (patCon pc), [e])))
        end
      | PRecord xpts =>
        foldl (fn ((x, pt, _), (env, p)) =>
                  let
                      val (env, p') = evalPat env (Proj (e, x)) pt
                  in
                      (env, And (p', p))
                  end) (env, True) xpts
      | PNone _ => (env, Reln (DtCon "None", [e]))
      | PSome (_, pt) =>
        let
            val (env, p) = evalPat env (Func ("unSome", [e])) pt
        in
            (env, And (p, Reln (DtCon "Some", [e])))
        end

fun peq (p1, p2) =
    case (p1, p2) of
        (True, True) => true
      | (False, False) => true
      | (Unknown, Unknown) => true
      | (And (x1, y1), And (x2, y2)) => peq (x1, x2) andalso peq (y1, y2)
      | (Or (x1, y1), Or (x2, y2)) => peq (x1, x2) andalso peq (y1, y2)
      | (Reln (r1, es1), Reln (r2, es2)) => r1 = r2 andalso ListPair.allEq eeq (es1, es2)
      | (Cond (e1, p1), Cond (e2, p2)) => eeq (e1, e2) andalso peq (p1, p2)
      | _ => false

fun removeRedundant p1 =
    let
        fun rr p2 =
            if peq (p1, p2) then
                True
            else
                case p2 of
                    And (x, y) => And (rr x, rr y)
                  | Or (x, y) => Or (rr x, rr y)
                  | _ => p2
    in
        rr
    end

fun evalExp env (e as (_, loc), st as (nv, p, sent)) =
    let
        fun default () =
            ((*Print.preface ("Default" ^ Int.toString nv,
                            MonoPrint.p_exp MonoEnv.empty e);*)
            (Var nv, (nv+1, p, sent)))

        fun addSent (p, e, sent) =
            if isKnown e then
                sent
            else
                (loc, e, p) :: sent
    in
        case #1 e of
            EPrim p => (Const p, st)
          | ERel n => (List.nth (env, n), st)
          | ENamed _ => default ()
          | ECon (_, pc, NONE) => (Func (patCon pc, []), st)
          | ECon (_, pc, SOME e) =>
            let
                val (e, st) = evalExp env (e, st)
            in
                (Func (patCon pc, [e]), st)
            end
          | ENone _ => (Func ("None", []), st)
          | ESome (_, e) =>
            let
                val (e, st) = evalExp env (e, st)
            in
                (Func ("Some", [e]), st)
            end
          | EFfi _ => default ()

          | EFfiApp (m, s, es) =>
            if m = "Basis" andalso SS.member (writers, s) then
                let
                    val (es, st) = ListUtil.foldlMap (evalExp env) st es
                in
                    (Recd [], (#1 st, p, foldl (fn (e, sent) => addSent (#2 st, e, sent)) sent es))
                end
            else if Settings.isEffectful (m, s) andalso not (Settings.isBenignEffectful (m, s)) then
                default ()
            else
                let
                    val (es, st) = ListUtil.foldlMap (evalExp env) st es
                in
                    (Func (m ^ "." ^ s, es), st)
                end

          | EApp (e1, e2) =>
            let
                val (e1, st) = evalExp env (e1, st)
            in
                case e1 of
                    Finish => (Finish, st)
                  | _ => default ()
            end

          | EAbs _ => default ()
          | EUnop (s, e1) =>
            let
                val (e1, st) = evalExp env (e1, st)
            in
                (Func (s, [e1]), st)
            end
          | EBinop (s, e1, e2) =>
            let
                val (e1, st) = evalExp env (e1, st)
                val (e2, st) = evalExp env (e2, st)
            in
                (Func (s, [e1, e2]), st)
            end
          | ERecord xets =>
            let
                val (xes, st) = ListUtil.foldlMap (fn ((x, e, _), st) =>
                                                      let
                                                          val (e, st) = evalExp env (e, st)
                                                      in
                                                          ((x, e), st)
                                                      end) st xets
            in
                (Recd xes, st)
            end
          | EField (e, s) =>
            let
                val (e, st) = evalExp env (e, st)
            in
                (Proj (e, s), st)
            end
          | ECase (e, pes, _) =>
            let
                val (e, st) = evalExp env (e, st)
                val r = #1 st
                val st = (r + 1, #2 st, #3 st)
                val orig = #2 st

                val st = foldl (fn ((pt, pe), st) =>
                                   let
                                       val (env, pp) = evalPat env e pt
                                       val (pe, st') = evalExp env (pe, (#1 st, And (orig, pp), #3 st))
                                                       
                                       val this = And (removeRedundant orig (#2 st'), Reln (Eq, [Var r, pe]))
                                   in
                                       (#1 st', Or (#2 st, this), #3 st')
                                   end) (#1 st, False, #3 st) pes
            in
                (Var r, (#1 st, And (orig, #2 st), #3 st))
            end
          | EStrcat (e1, e2) =>
            let
                val (e1, st) = evalExp env (e1, st)
                val (e2, st) = evalExp env (e2, st)
            in
                (Func ("cat", [e1, e2]), st)
            end
          | EError _ => (Finish, st)
          | EReturnBlob {blob = b, mimeType = m, ...} =>
            let
                val (b, st) = evalExp env (b, st)
                val (m, st) = evalExp env (m, st)
            in
                (Finish, (#1 st, p, addSent (#2 st, b, addSent (#2 st, m, sent))))
            end
          | ERedirect (e, _) =>
            let
                val (e, st) = evalExp env (e, st)
            in
                (Finish, (#1 st, p, addSent (#2 st, e, sent)))
            end
          | EWrite e =>
            let
                val (e, st) = evalExp env (e, st)
            in
                (Recd [], (#1 st, p, addSent (#2 st, e, sent)))
            end
          | ESeq (e1, e2) =>
            let
                val (_, st) = evalExp env (e1, st)
            in
                evalExp env (e2, st)
            end
          | ELet (_, _, e1, e2) =>
            let
                val (e1, st) = evalExp env (e1, st)
            in
                evalExp (e1 :: env) (e2, st)
            end
          | EClosure (n, es) =>
            let
                val (es, st) = ListUtil.foldlMap (evalExp env) st es
            in
                (Func ("Cl" ^ Int.toString n, es), st)
            end

          | EQuery {query = q, body = b, initial = i, ...} =>
            let
                val (_, st) = evalExp env (q, st)
                val (i, st) = evalExp env (i, st)

                val r = #1 st
                val acc = #1 st + 1
                val st' = (#1 st + 2, #2 st, #3 st)

                val (b, st') = evalExp (Var acc :: Var r :: env) (b, st')

                val (rvN, count, qp, used) =
                    queryProp env
                              (#1 st') (fn rvN => (rvN + 1, Var rvN))
                              (AllCols (Var r)) q

                val p' = And (qp, #2 st')

                val (nvs, p, res) = if varInP acc (#2 st') then
                                        (#1 st + 1, #2 st, Var r)
                                    else
                                        let
                                            val out = rvN

                                            val p = Or (Reln (Eq, [Var out, i]),
                                                        And (Reln (Eq, [Var out, b]),
                                                             And (Reln (Gt, [count,
                                                                             Const (Prim.Int 0)]),
                                                                  p')))
                                        in
                                            (out + 1, p, Var out)
                                        end

                val sent = map (fn (loc, e, p) => (loc, e, And (qp, p))) (#3 st')
                val sent = map (fn e => (loc, e, p')) used @ sent
            in
                (res, (nvs, p, sent))
            end
          | EDml _ => default ()
          | ENextval _ => default ()
          | ESetval _ => default ()

          | EUnurlify ((EFfiApp ("Basis", "get_cookie", _), _), _, _) =>
            (Var nv, (nv + 1, And (p, Reln (Known, [Var nv])), sent))

          | EUnurlify _ => default ()
          | EJavaScript _ => default ()
          | ESignalReturn _ => default ()
          | ESignalBind _ => default ()
          | ESignalSource _ => default ()
          | EServerCall _ => default ()
          | ERecv _ => default ()
          | ESleep _ => default ()
          | ESpawn _ => default ()
    end

fun check file =
    let
        val file = MonoReduce.reduce file
        val file = MonoOpt.optimize file
        val file = Fuse.fuse file
        val file = MonoOpt.optimize file
        (*val () = Print.preface ("File", MonoPrint.p_file MonoEnv.empty file)*)

        val exptd = foldl (fn ((d, _), exptd) =>
                              case d of
                                  DExport (_, _, n, _, _, _) => IS.add (exptd, n)
                                | _ => exptd) IS.empty file

        fun decl ((d, _), (vals, pols)) =
            case d of
                DVal (_, n, _, e, _) =>
                let
                    val isExptd = IS.member (exptd, n)

                    fun deAbs (e, env, nv, p) =
                        case #1 e of
                            EAbs (_, _, _, e) => deAbs (e, Var nv :: env, nv + 1,
                                                        if isExptd then
                                                            And (p, Reln (Known, [Var nv]))
                                                        else
                                                            p)
                          | _ => (e, env, nv, p)

                    val (e, env, nv, p) = deAbs (e, [], 1, True)

                    val (e, (_, p, sent)) = evalExp env (e, (nv, p, []))
                in
                    (sent @ vals, pols)
                end

              | DPolicy (PolClient e) => (vals, #3 (queryProp [] 0 (fn rvN => (rvN + 1, Lvar rvN))
                                                              (SomeCol (Var 0)) e) :: pols)
                                        
              | _ => (vals, pols)

        val () = reset ()

        val (vals, pols) = foldl decl ([], []) file
    in
        app (fn (loc, e, p) =>
                let
                    fun doOne e =
                        let
                            val p = And (p, Reln (Eq, [Var 0, e]))
                        in
                            if List.exists (fn pol => if imply (p, pol) then
                                                          (if !debug then
                                                               Print.prefaces "Match"
                                                                              [("Hyp", p_prop p),
                                                                               ("Goal", p_prop pol)]
                                                           else
                                                               ();
                                                           true)
                                                      else
                                                          false) pols then
                                ()
                            else
                                (ErrorMsg.errorAt loc "The information flow policy may be violated here.";
                                 Print.preface ("The state satisifes this predicate:", p_prop p))
                        end

                    fun doAll e =
                        case e of
                            Const _ => ()
                          | Var _ => doOne e
                          | Lvar _ => raise Fail "Iflow.doAll: Lvar"
                          | Func (f, es) => if String.isPrefix "un" f then
                                                doOne e
                                            else
                                                app doAll es
                          | Recd xes => app (doAll o #2) xes
                          | Proj _ => doOne e
                          | Finish => ()
                in
                    doAll e
                end) vals
    end

val check = fn file =>
               let
                   val oldInline = Settings.getMonoInline ()
               in
                   (Settings.setMonoInline (case Int.maxInt of
                                                NONE => 1000000
                                              | SOME n => n);
                    check file;
                    Settings.setMonoInline oldInline)
                   handle ex => (Settings.setMonoInline oldInline;
                                 raise ex)
               end

end

